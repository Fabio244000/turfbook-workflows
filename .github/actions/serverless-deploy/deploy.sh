#!/usr/bin/env bash
# Deploy: verify, change, roll back (ticket-manager/conventions/platform.md, §8).
#   1. Verify the requirements; something missing -> fail, nothing changed.
#   2. Provision the service database once (db-provisioner of turfbook-platform).
#   3. Record the database revision (migrate Lambda, action "current").
#   4. serverless deploy with CloudFormation's automatic rollback disabled
#      (disableRollback in the service's serverless.yml).
#   5. The deploy failed: undo the migrations with the new code's migrate Lambda, the
#      only one with the migration files, then roll back the stack (delete it on a first
#      deploy). If the undo fails, stop without touching the stack and report it.
#
# Required env: STAGE, SERVICE, SERVERLESS_ACCESS_KEY. Optional: DB_SECRET_NAME (empty:
# no database), VERIFY_SCRIPT, REDEPLOY ('true'), MIGRATIONS_HASH.
# Needs AWS credentials and npm ci done. Works the same from a developer machine.
set -euo pipefail

: "${STAGE:?STAGE is required}"
: "${SERVICE:?SERVICE is required}"
: "${SERVERLESS_ACCESS_KEY:?SERVERLESS_ACCESS_KEY is required}"
DB_SECRET_NAME="${DB_SECRET_NAME:-}"
REDEPLOY="${REDEPLOY:-false}"
MIGRATIONS_HASH="${MIGRATIONS_HASH:-}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export STACK_NAME="turfbook-$SERVICE-$STAGE"
export MIGRATE_FUNCTION="turfbook-$SERVICE-$STAGE-migrate"
export DB_PROVISIONER_FUNCTION="turfbook-platform-$STAGE-db-provisioner"
export DB_PROVISIONED_PARAM="/turfbook/$SERVICE/$STAGE/db_provisioned"
export STAGE DB_SECRET_NAME

stack_status() {
  aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo NONE
}

# Serverless reports a failed deploy as soon as one resource fails, while CloudFormation
# is still working on the rest (…_IN_PROGRESS). Undoing the migrations or rolling back
# before it settles races with it, and RollbackStack is refused until the stack is
# UPDATE_FAILED or CREATE_FAILED. Waits up to 20 minutes for a final status.
settled_stack_status() {
  local status deadline=$((SECONDS + 1200))
  status="$(stack_status)"
  while [[ "$status" == *_IN_PROGRESS ]]; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "::error::Stack $STACK_NAME still $status after 20 minutes." >&2
      break
    fi
    sleep 10
    status="$(stack_status)"
  done
  echo "$status"
}

# 1. Verify (nothing changes before this passes).
before="$(stack_status)"
case "$before" in
  NONE | CREATE_COMPLETE | UPDATE_COMPLETE | UPDATE_ROLLBACK_COMPLETE) ;;
  *)
    echo "::error::Stack $STACK_NAME is $before: fix it before deploying (no changes made)."
    exit 1
    ;;
esac
bash "$here/verify.sh"
first_deploy=false
if [ "$before" = NONE ]; then first_deploy=true; fi

# 2. Provision the database once.
if [ -n "$DB_SECRET_NAME" ]; then
  bash "$here/provision_database.sh"
fi

# 3. Record the revision (a first deploy has no migrate Lambda yet: nothing to record).
recorded=''
if [ -n "$DB_SECRET_NAME" ] && [ "$first_deploy" = false ]; then
  recorded="$(bash "$here/migrate.sh" current)"
  echo "Database revision before the deploy: ${recorded:-base}"
fi

# Redeploy of an earlier commit: it belongs to develop, and its migrations end at the
# deployed revision (the old code cannot run on a newer schema).
if [ "$REDEPLOY" = true ] && ! git merge-base --is-ancestor HEAD origin/develop; then
  echo "::error::The commit to redeploy is not on develop (no changes made)."
  exit 1
fi
if [ "$REDEPLOY" = true ] && [ -n "$DB_SECRET_NAME" ]; then
  if ! python3 "$here/check_head.py" alembic/versions "$recorded"; then
    echo "::error::The commit's migrations do not end at the deployed revision: revert through a pull request instead (no changes made)."
    exit 1
  fi
fi

# 4. Change.
# --force: Serverless compares with the last package it uploaded, which after a rollback
# is the failed one, and would skip ("No changes to deploy") while the stack stays on the
# old version. CloudFormation compares with the real stack: no change, no update.
if npx serverless deploy --stage "$STAGE" --param="migrationsHash=$MIGRATIONS_HASH" --force; then
  exit 0
fi

# 5. Roll back, once CloudFormation has finished.
after="$(settled_stack_status)"
echo "::error::Deploy failed (stack $after): rolling back."

if [ "$first_deploy" = true ]; then
  if [ -n "$DB_SECRET_NAME" ] && aws lambda get-function --function-name "$MIGRATE_FUNCTION" > /dev/null 2>&1; then
    if ! bash "$here/migrate.sh" downgrade base > /dev/null; then
      echo "::error::Undoing the migrations failed: the stack is kept for Fabio to check the database."
      exit 1
    fi
    echo 'Migrations undone: the database is at base.'
  fi
  if [ "$after" != NONE ]; then
    aws cloudformation delete-stack --stack-name "$STACK_NAME"
    aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME"
  fi
  echo 'First deploy rolled back: the stack is deleted and the database is empty.'
  exit 1
fi

if [ "$after" = "$before" ]; then
  echo 'The stack did not change: nothing to roll back.'
  exit 1
fi

if [ -n "$DB_SECRET_NAME" ]; then
  if ! bash "$here/migrate.sh" downgrade "${recorded:-base}" > /dev/null; then
    echo "::error::Undoing the migrations failed: the stack is not rolled back (the old code cannot run on the new schema). Fabio: check the database revision, then continue the rollback in the console."
    exit 1
  fi
  echo "Migrations undone: the database is back at ${recorded:-base}."
fi
aws cloudformation rollback-stack --stack-name "$STACK_NAME"
aws cloudformation wait stack-rollback-complete --stack-name "$STACK_NAME"
echo 'Deploy rolled back: the stack and the database are as they were.'
exit 1

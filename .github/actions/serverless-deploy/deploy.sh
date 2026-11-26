#!/usr/bin/env bash
# Deploy: verify, change, roll back. A failed deploy leaves nothing behind.
#   1. Verify the requirements; something missing -> fail, nothing changed.
#   2. Provision the service database once (the shared db-provisioner). If it fails,
#      drop whatever it created: nothing is left.
#   3. Record the database revision (migrate Lambda, action "current"). A migrate that
#      predates the direct actions cannot answer: its first deploy with them has no
#      recorded revision, so it keeps CloudFormation's automatic rollback.
#   4. serverless deploy. The rollback is decided per deploy: disabled only when the
#      deploy brings new migrations (the commit's head is not the recorded revision),
#      CloudFormation's automatic one otherwise (--param disableRollback, read by the
#      service's serverless.yml). CloudFormation refuses to replace a resource with the
#      rollback disabled (the layer, whenever requirements/base.txt changes).
#   5. The deploy failed. Automatic rollback: CloudFormation already undid it. Rollback
#      disabled: undo the migrations with the new code's migrate Lambda, the only one
#      with the migration files, then roll back the stack. If the undo fails, stop
#      without touching the stack and report it.
#      A first deploy is undone as if it never happened: delete the stack, then drop the
#      database and its user if this deploy created them. A database that existed
#      before this deploy may hold data: it is never dropped.
#
# Required env: STAGE, SERVICE, SERVERLESS_ACCESS_KEY. Optional: DB_SECRET_NAME (empty:
# no database), VERIFY_SCRIPT, REDEPLOY ('true'), MIGRATIONS_HASH (empty: not passed).
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
db_created_now=false
if [ -n "$DB_SECRET_NAME" ]; then
  if [ "$(bash "$here/provision_database.sh" is-provisioned)" != true ]; then
    db_created_now=true
  fi
  if ! bash "$here/provision_database.sh"; then
    if [ "$db_created_now" = true ]; then
      echo '::error::Provisioning failed: dropping whatever it created.'
      if ! bash "$here/provision_database.sh" drop; then
        echo "::error::Dropping it failed too. Fabio: check the database and its user, and set $DB_PROVISIONED_PARAM to false once they are gone."
        exit 1
      fi
      echo 'Provisioning undone: neither the database nor its user is left.'
    fi
    exit 1
  fi
fi

# 3. Record the revision (a first deploy has no migrate Lambda yet: nothing to record).
recorded=''
legacy_migrate=false
if [ -n "$DB_SECRET_NAME" ] && [ "$first_deploy" = false ]; then
  migrate_error="$(mktemp)"
  if recorded="$(bash "$here/migrate.sh" current 2> "$migrate_error")"; then
    echo "Database revision before the deploy: ${recorded:-base}"
  elif grep -q ResponseURL "$migrate_error"; then
    # Only a custom-resource handler reads ResponseURL: the old migrate.
    legacy_migrate=true
    recorded=''
    echo '::warning::The deployed migrate predates the direct actions: the database revision is unknown. This deploy keeps CloudFormation'"'"'s automatic rollback and must bring no new migrations.'
  else
    cat "$migrate_error" >&2
    exit 1
  fi
  rm -f "$migrate_error"
fi

# Redeploy of an earlier commit: it belongs to develop, and its migrations end at the
# deployed revision (the old code cannot run on a newer schema).
if [ "$REDEPLOY" = true ] && ! git merge-base --is-ancestor HEAD origin/develop; then
  echo "::error::The commit to redeploy is not on develop (no changes made)."
  exit 1
fi
if [ "$REDEPLOY" = true ] && [ "$legacy_migrate" = true ]; then
  echo "::error::A redeploy needs the database revision, and the deployed migrate cannot give it: deploy develop first (no changes made)."
  exit 1
fi
if [ "$REDEPLOY" = true ] && [ -n "$DB_SECRET_NAME" ]; then
  if ! python3 "$here/check_head.py" alembic/versions "$recorded"; then
    echo "::error::The commit's migrations do not end at the deployed revision: revert through a pull request instead (no changes made)."
    exit 1
  fi
fi

# 4. Change. Only new migrations need the rollback disabled (step 5 undoes them first).
new_migrations=false
if [ -n "$DB_SECRET_NAME" ] && [ "$legacy_migrate" = false ] \
  && ! python3 "$here/check_head.py" alembic/versions "$recorded" > /dev/null; then
  new_migrations=true
fi
echo "New migrations: $new_migrations (CloudFormation rollback disabled: $new_migrations)."

# --force: Serverless compares with the last package it uploaded, which after a rollback
# is the failed one, and would skip ("No changes to deploy") while the stack stays on the
# old version. CloudFormation compares with the real stack: no change, no update.
# migrationsHash only when there is one: Serverless rejects an empty --param while
# resolving any ${param:...}, and without it the template falls back to sls:instanceId.
params=(--param="disableRollback=$new_migrations")
if [ -n "$MIGRATIONS_HASH" ]; then
  params+=(--param="migrationsHash=$MIGRATIONS_HASH")
fi
if npx serverless deploy --stage "$STAGE" "${params[@]}" --force; then
  exit 0
fi

# 5. Roll back, once CloudFormation has finished.
after="$(settled_stack_status)"

# A replacement refused because the rollback was disabled: the deploy mixes new
# migrations with a change that replaces a resource.
split_hint() {
  if aws cloudformation describe-stack-events --stack-name "$STACK_NAME" \
    --query 'StackEvents[].ResourceStatusReason' --output text 2>/dev/null \
    | grep -q 'Replacement type updates not supported'; then
    echo '::error::The deploy brings new migrations and replaces a resource (e.g. the layer, from a dependency change): deploy the replacing change first in its own pull request, then the migrations.'
  fi
}

undo_first_deploy() {
  if [ -n "$DB_SECRET_NAME" ] && [ "$db_created_now" = false ] && [ "$new_migrations" = true ] \
    && aws lambda get-function --function-name "$MIGRATE_FUNCTION" > /dev/null 2>&1; then
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
  if [ "$db_created_now" = true ]; then
    if ! bash "$here/provision_database.sh" drop; then
      echo "::error::The stack is deleted, but dropping the database failed. Fabio: check the database and its user, and set $DB_PROVISIONED_PARAM to false once they are gone."
      exit 1
    fi
    echo 'First deploy undone: the stack, the database and its user are deleted.'
  elif [ -n "$DB_SECRET_NAME" ]; then
    echo 'First deploy undone: the stack is deleted; the database existed before this deploy and is kept.'
  else
    echo 'First deploy undone: the stack is deleted.'
  fi
  exit 1
}

if [ "$new_migrations" = false ]; then
  if [ "$first_deploy" = true ]; then
    echo "::error::First deploy failed (stack $after): undoing it."
    undo_first_deploy
  fi
  case "$after" in
    NONE | UPDATE_ROLLBACK_COMPLETE | "$before")
      echo "::error::Deploy failed: CloudFormation rolled it back (stack $after), the stack is as it was."
      ;;
    *)
      echo "::error::Deploy failed and the stack is $after: Fabio, check it in the console."
      ;;
  esac
  exit 1
fi

echo "::error::Deploy failed (stack $after): rolling back."
split_hint

if [ "$first_deploy" = true ]; then
  undo_first_deploy
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

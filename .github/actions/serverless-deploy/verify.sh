#!/usr/bin/env bash
# Verifies the deploy's requirements before anything changes
# (ticket-manager/conventions/platform.md, §8). A service with a database: the RDS
# instance is available, its secret exists and the db-provisioner is deployed. Then the
# service's own checks (VERIFY_SCRIPT, the requirements of its ticket's §8).
#
# Env: STAGE; optional DB_SECRET_NAME, DB_PROVISIONER_FUNCTION, VERIFY_SCRIPT.
set -euo pipefail

fail() {
  echo "::error::Deploy requirement missing: $1 (no changes made)."
  exit 1
}

if [ -n "${DB_SECRET_NAME:-}" ]; then
  db_host="$(aws ssm get-parameter --name "/turfbook/$STAGE/db_host" \
    --query Parameter.Value --output text)" || fail "parameter /turfbook/$STAGE/db_host"
  rds_status="$(aws rds describe-db-instances \
    --query "DBInstances[?Endpoint.Address=='$db_host'].DBInstanceStatus | [0]" \
    --output text)" || fail 'RDS instance (describe)'
  [ "$rds_status" = available ] || fail "RDS instance is ${rds_status:-missing}, not available"
  # Only the ARN is printed, never the secret value.
  aws secretsmanager get-secret-value --secret-id "$DB_SECRET_NAME" \
    --query ARN --output text > /dev/null || fail "secret $DB_SECRET_NAME"
  aws lambda get-function --function-name "$DB_PROVISIONER_FUNCTION" \
    > /dev/null || fail "Lambda $DB_PROVISIONER_FUNCTION"
  echo "Database requirements OK (RDS available, secret and provisioner present)."
fi

if [ -n "${VERIFY_SCRIPT:-}" ]; then
  bash "$VERIFY_SCRIPT" || fail "service check $VERIFY_SCRIPT"
fi

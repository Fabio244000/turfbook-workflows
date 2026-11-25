#!/usr/bin/env bash
# The service database, through the shared db-provisioner Lambda. The SSM flag
# DB_PROVISIONED_PARAM records whether it exists:
#   provision_database.sh                 -> creates it once: flag missing or "false",
#                                            invoke the provisioner and set it to "true";
#                                            "true", skip. Any provisioner error stops.
#   provision_database.sh is-provisioned  -> prints the flag ("false" when missing)
#   provision_database.sh drop            -> drops the database and its user (the
#                                            password proves the service owns them) and
#                                            sets the flag to "false"
#
# The password is never printed: it only lives in a private temp file that is
# removed on exit.
#
# Required env: DB_SECRET_NAME, DB_PROVISIONER_FUNCTION, DB_PROVISIONED_PARAM.
# Needs AWS credentials. Works the same in GitHub Actions and from a developer machine.
set -euo pipefail

: "${DB_SECRET_NAME:?DB_SECRET_NAME is required}"
: "${DB_PROVISIONER_FUNCTION:?DB_PROVISIONER_FUNCTION is required}"
: "${DB_PROVISIONED_PARAM:?DB_PROVISIONED_PARAM is required}"

umask 077
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

read_provisioned_flag() {
  local value
  if value="$(aws ssm get-parameter --name "$DB_PROVISIONED_PARAM" \
      --query Parameter.Value --output text 2> "$workdir/ssm_error")"; then
    echo "$value"
  elif grep -q ParameterNotFound "$workdir/ssm_error"; then
    echo false
  else
    cat "$workdir/ssm_error" >&2
    return 1
  fi
}

# $1: the provisioner action; empty creates.
build_payload() {
  aws secretsmanager get-secret-value \
    --secret-id "$DB_SECRET_NAME" \
    --query SecretString \
    --output text > "$workdir/secret.json"

  python3 - "$workdir/secret.json" "$workdir/payload.json" "${1:-}" <<'PY'
import json
import os
import sys

secret_path, payload_path, action = sys.argv[1], sys.argv[2], sys.argv[3]
with open(secret_path) as file:
    secret = json.load(file)

missing = [key for key in ('dbname', 'username', 'password') if not secret.get(key)]
if missing:
    sys.exit(f'Secret is missing keys: {", ".join(missing)}')

if os.environ.get('GITHUB_ACTIONS') == 'true':
    print(f'::add-mask::{secret["password"]}')

payload = {
    'db_name': secret['dbname'],
    'username': secret['username'],
    'password': secret['password'],
}
if action:
    payload['action'] = action
with open(payload_path, 'w') as file:
    json.dump(payload, file)
PY
}

invoke_provisioner() {
  local function_error
  function_error="$(aws lambda invoke \
    --function-name "$DB_PROVISIONER_FUNCTION" \
    --cli-binary-format raw-in-base64-out \
    --payload "file://$workdir/payload.json" \
    --query FunctionError \
    --output text \
    "$workdir/response.json")"

  if [ "$function_error" != "None" ]; then
    echo "db-provisioner failed ($function_error):" >&2
    cat "$workdir/response.json" >&2
    return 1
  fi
  echo "db-provisioner response: $(cat "$workdir/response.json")"
}

set_provisioned_flag() {
  aws ssm put-parameter --name "$DB_PROVISIONED_PARAM" \
    --value "$1" --type String --overwrite > /dev/null
}

case "${1:-create}" in
  create) ;;
  is-provisioned)
    read_provisioned_flag
    exit 0
    ;;
  drop)
    build_payload drop
    invoke_provisioner
    set_provisioned_flag false
    echo "Database dropped; $DB_PROVISIONED_PARAM set to false."
    exit 0
    ;;
  *) echo "Unknown action: $1" >&2; exit 2 ;;
esac

provisioned="$(read_provisioned_flag)"
if [ "$provisioned" = "true" ]; then
  echo "Database already provisioned ($DB_PROVISIONED_PARAM = true); skipping."
  exit 0
fi

build_payload
invoke_provisioner
set_provisioned_flag true
echo "Provisioned; $DB_PROVISIONED_PARAM set to true."

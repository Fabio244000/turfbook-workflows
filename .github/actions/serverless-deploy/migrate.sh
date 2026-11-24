#!/usr/bin/env bash
# Invokes the service's migrate Lambda directly (not through CloudFormation).
#   migrate.sh current             -> prints the database revision (empty: base)
#   migrate.sh downgrade <revision> -> undoes the migrations down to <revision> ('base':
#                                      all of them); prints the revision reached
# Contract of the Lambda: event {"action": "current"} or {"action": "downgrade",
# "revision": "<rev>"}; reply {"revision": "<rev>" | null}; an error is a FunctionError.
#
# Env: MIGRATE_FUNCTION.
set -euo pipefail

: "${MIGRATE_FUNCTION:?MIGRATE_FUNCTION is required}"
action="${1:?action is required: current or downgrade}"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

case "$action" in
  current) payload='{"action": "current"}' ;;
  downgrade)
    revision="${2:?revision is required}"
    payload="$(python3 -c 'import json, sys; print(json.dumps({"action": "downgrade", "revision": sys.argv[1]}))' "$revision")"
    ;;
  *) echo "Unknown action: $action" >&2; exit 2 ;;
esac

function_error="$(aws lambda invoke \
  --function-name "$MIGRATE_FUNCTION" \
  --cli-binary-format raw-in-base64-out \
  --payload "$payload" \
  --query FunctionError \
  --output text \
  "$workdir/response.json")"

if [ "$function_error" != None ]; then
  echo "migrate $action failed ($function_error):" >&2
  cat "$workdir/response.json" >&2
  exit 1
fi

python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get("revision") or "")' "$workdir/response.json"

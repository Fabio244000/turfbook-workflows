#!/usr/bin/env bash
# Runs the tests a change needs.
# - Not a pull request (develop, manual run): the whole suite, recording testmon data.
# - Pull request that changes something that is not Python code (migrations,
#   dependencies, configuration, deploy, workflows): the whole suite.
# - Any other pull request: the tests affected by the change, then every e2e test.
# Needs pytest-testmon in requirements/local.txt and the base commit fetched.
set -euo pipefail

FULL_SUITE_PATHS='^(alembic/|requirements/|config/|deploy/|\.github/|pyproject\.toml$|serverless\.yml$|package(-lock)?\.json$)'

if [ "$EVENT_NAME" != 'pull_request' ]; then
  echo 'Whole suite, recording testmon data (not a pull request).'
  exec pytest --testmon-noselect
fi

if [ ! -f .testmondata ]; then
  echo 'Whole suite: no testmon data from the base branch.'
  exec pytest
fi

changed=$(git diff --name-only "$BASE_SHA" HEAD)
if full=$(grep -E "$FULL_SUITE_PATHS" <<<"$changed"); then
  echo 'Whole suite: the pull request changes files that are not Python code:'
  echo "$full"
  exec pytest
fi

echo 'Tests affected by the change:'
status=0
pytest --testmon-nocollect --ignore-glob='tests/*/e2e/*' || status=$?
# 5: every test was deselected (nothing affected), which is not a failure.
if [ "$status" -ne 0 ] && [ "$status" -ne 5 ]; then
  exit "$status"
fi

if compgen -G 'tests/*/e2e' >/dev/null; then
  echo 'Every e2e test:'
  pytest tests/*/e2e
fi

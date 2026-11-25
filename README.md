# turfbook-workflows

Shared GitHub Actions for the TurfBook services: reusable workflows and composite actions.
A service calls them pinned to a full commit SHA; Dependabot in the service proposes the
updates.

## Map

```
service repo                                  turfbook-workflows
.github/workflows/ci.yml      ──uses@SHA──►   workflows/python-ci.yml
                                                ├─ pre-commit ──► actions/setup-python-env (mypy cache)
                                                ├─ tests ───────► actions/setup-service (+ alembic check), actions/run-tests
                                                ├─ audit ───────► pip-audit of requirements/base.txt
                                                └─ coverage ────► actions/setup-service (outside a PR, ≥ 90%)
.github/workflows/deploy.yml  ──► ci.yml, then
                              ──uses@SHA──►   workflows/serverless-deploy.yml (arm64)
                                                └─ deploy ──────► actions/setup-serverless, actions/serverless-deploy
                                                                  (verify → provision → record revision → deploy → roll back on failure)
```

## Reusable workflows

| Workflow | Jobs | Inputs | Secrets |
|---|---|---|---|
| `.github/workflows/python-ci.yml` | `pre-commit` ‖ `tests` (`setup-service`, `alembic check` when `postgres-db` is set, then `run-tests`) ‖ `audit` (`pip-audit -r requirements/base.txt`) ‖ `coverage` (outside a PR only: the whole suite with `--cov=app --cov-fail-under=90`; testmon stops recording under coverage, so it is its own job). Required checks: `Pre-commit`, `Tests`, `Audit` | `postgres-db` (empty = no Postgres), `ci-env` (non-secret `KEY=value` lines), `setup-script` (path in the service repo, run before the tests), `ref` (commit to test; empty = the event's) | — |
| `.github/workflows/serverless-deploy.yml` | `deploy` on `ubuntu-24.04-arm` in the GitHub Environment `stage`: checkout of `ref`, Serverless, layer cache, OIDC, the service's setup script, then `serverless-deploy` | `stage`, `service` (required), `db-secret` (empty = no database), `verify-script`, `setup-script`, `ref` (an earlier commit = redeploy) | `SERVERLESS_ACCESS_KEY`, `AWS_DEPLOY_ROLE_ARN` (passed explicitly) |
| `.github/workflows/serverless-package.yml` | `package` on `ubuntu-24.04-arm`: `serverless package`, layer reused from the cache while `requirements/base.txt` does not change | `stage` (required), `setup-script` (run before packaging) | `SERVERLESS_ACCESS_KEY` (passed explicitly) |

Example (a service with a database):

```yaml
jobs:
  ci:
    uses: <owner>/turfbook-workflows/.github/workflows/python-ci.yml@<full SHA> # main
    with:
      postgres-db: identity
      ci-env: |
        ACCOUNTS_API_KEY=ci-accounts-api-key
      setup-script: scripts/ci/session_token_key.sh
```

## Composite actions

| Action | What it does | Inputs |
|---|---|---|
| `.github/actions/setup-python-env` | Python 3.12 and `requirements/local.txt` in `~/venv`, cached by the Python version and the hash of `requirements/*.txt` (a hit skips `pip install`); optionally the mypy cache | `mypy-cache` (`'true'` / `'false'`, default `'false'`) |
| `.github/actions/setup-serverless` | Node 22 and `npm ci` (Serverless pinned in the service's `package.json`) | — |
| `.github/actions/setup-service` | Postgres in the background (only with `postgres-db`, pinned by digest), `setup-python-env`, `DATABASE_URL` and `ci-env` in the environment, the service's setup script, the wait for Postgres and `alembic upgrade head` | `postgres-db`, `ci-env`, `setup-script` |
| `.github/actions/serverless-deploy` | `deploy.sh` (`ticket-manager/conventions/platform.md` §8): verifies the requirements (`verify.sh`: RDS available, the secret and the provisioner; then the service's `verify-script`) with no changes if one is missing; provisions the database once (`provision_database.sh`; if it fails, `drop` removes whatever it created); records the revision (`migrate.sh current`); a redeploy must be on `develop` and its migrations must end at the deployed revision (`check_head.py`); `serverless deploy --param disableRollback=<new migrations>`: CloudFormation's rollback is disabled only when the commit's head is not the recorded revision (`check_head.py`), automatic otherwise (it allows replacing a resource, e.g. the layer); the service reads it with `${strToBool(${param:disableRollback, 'true'})}`. On failure with the automatic rollback: CloudFormation already undid it (a first deploy's stack is deleted). With it disabled: `migrate.sh downgrade` to the recorded revision (to `base` on a first deploy) with the new code's `migrate`, then `rollback-stack` (`delete-stack` on a first deploy); if the downgrade fails, it stops without touching the stack; a replacement refused for mixing it with new migrations says to deploy them in separate pull requests. A failed first deploy is undone as if it never happened: the stack is deleted, then, if this deploy created the database (`db_provisioned` was not `true` before it), `provision_database.sh drop` invokes the db-provisioner's `drop` with the secret's password (masked) and sets `db_provisioned` to `false`; a database that existed before is never dropped. The `migrate` Lambda of the service accepts `{"action": "current"}` and `{"action": "downgrade", "revision": "<rev>"}` and replies `{"revision": "<rev>" \| null}` | `stage`, `service`, `db-secret`, `verify-script`, `redeploy`, `migrations-hash`, `serverless-access-key` |
| `.github/actions/run-tests` | Outside a pull request, the whole suite, saving testmon data. In a pull request, the affected tests (pytest-testmon, data of the base branch) plus every `tests/*/e2e` test; the whole suite when it changes `alembic/`, `requirements/`, `config/`, `deploy/`, `.github/`, `pyproject.toml`, `serverless.yml` or `package*.json`, or when there is no testmon data. The service needs `pytest-testmon` in `requirements/local.txt` | — |

## Checks before push

`pre-commit install` once; every commit runs actionlint and zizmor (`--persona=pedantic`,
which also rejects broad permissions such as `write-all`). The Postgres image of
`python-ci.yml` is pinned by digest and Dependabot does not update it: bump it by hand.

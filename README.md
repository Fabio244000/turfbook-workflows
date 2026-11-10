# turfbook-workflows

Shared GitHub Actions for the TurfBook services: reusable workflows and composite actions.
A service calls them pinned to a full commit SHA; Dependabot in the service proposes the
updates.

## Map

```
service repo                                  turfbook-workflows
.github/workflows/ci.yml      ──uses@SHA──►   workflows/python-ci.yml
                                                ├─ pre-commit ──► actions/setup-python-env (mypy cache)
                                                └─ tests ───────► actions/setup-python-env (+ Postgres if postgres-db)
.github/workflows/deploy.yml  ──► ci.yml, then
                              ──uses@SHA──►   workflows/serverless-package.yml (arm64)
                                                └─ package ─────► actions/setup-serverless
```

## Reusable workflows

| Workflow | Jobs | Inputs | Secrets |
|---|---|---|---|
| `.github/workflows/python-ci.yml` | `pre-commit` ‖ `tests` (Postgres only when `postgres-db` is set, started in the background while the environment is prepared; migrations, then `run-tests`) | `postgres-db` (empty = no Postgres), `ci-env` (non-secret `KEY=value` lines), `setup-script` (path in the service repo, run before the tests) | — |
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
| `.github/actions/run-tests` | Outside a pull request, the whole suite, saving testmon data. In a pull request, the affected tests (pytest-testmon, data of the base branch) plus every `tests/*/e2e` test; the whole suite when it changes `alembic/`, `requirements/`, `config/`, `deploy/`, `.github/`, `pyproject.toml`, `serverless.yml` or `package*.json`, or when there is no testmon data. The service needs `pytest-testmon` in `requirements/local.txt` | — |

## Checks before push

`pre-commit install` once; every commit runs actionlint and zizmor (`--persona=pedantic`,
which also rejects broad permissions such as `write-all`). The Postgres image of
`python-ci.yml` is pinned by digest and Dependabot does not update it: bump it by hand.

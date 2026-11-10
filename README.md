# turfbook-workflows

Shared GitHub Actions for the TurfBook services: reusable workflows and composite actions.
A service calls them pinned to a full commit SHA; Dependabot in the service proposes the
updates.

## Composite actions

| Action | What it does | Inputs |
|---|---|---|
| `.github/actions/setup-python-env` | Python 3.12 and `requirements/local.txt` in `~/venv`, cached by the Python version and the hash of `requirements/*.txt` (a hit skips `pip install`); optionally the mypy cache | `mypy-cache` (`'true'` / `'false'`, default `'false'`) |
| `.github/actions/setup-serverless` | Node 22 and `npm ci` (Serverless pinned in the service's `package.json`) | — |

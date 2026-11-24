"""Checks that the migrations of a commit end at the deployed revision (redeploy).

Usage: check_head.py <alembic/versions dir> <deployed revision, empty for base>
Exit 0 when the single head of the directory is the deployed revision (or there are no
migrations and the database is at base); 1 otherwise. Reads the revision files as text:
no project import, no database.
"""

import re
import sys
from pathlib import Path

REVISION = re.compile(r'^revision\s*(?::[^=]*)?=\s*[\'"]([^\'"]+)[\'"]', re.MULTILINE)
DOWN_REVISION = re.compile(r'^down_revision\s*(?::[^=]*)?=\s*(.+)$', re.MULTILINE)
QUOTED = re.compile(r'[\'"]([^\'"]+)[\'"]')


def heads(versions: Path) -> set[str]:
    revisions: set[str] = set()
    parents: set[str] = set()
    for path in versions.glob('*.py'):
        text = path.read_text()
        revision = REVISION.search(text)
        if revision is None:
            continue
        revisions.add(revision.group(1))
        down = DOWN_REVISION.search(text)
        if down is not None:
            parents.update(QUOTED.findall(down.group(1)))
    return revisions - parents


def main() -> int:
    versions, deployed = Path(sys.argv[1]), sys.argv[2]
    found = heads(versions) if versions.is_dir() else set()
    expected = {deployed} if deployed else set()
    if found == expected:
        print(f'Migrations end at the deployed revision ({deployed or "base"}).')
        return 0
    print(f'Heads {sorted(found) or ["base"]} != deployed {deployed or "base"}.')
    return 1


if __name__ == '__main__':
    sys.exit(main())

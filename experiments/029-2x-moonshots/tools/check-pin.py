"""Check a frozen baseline's MD5 manifest before a run."""
import hashlib
from pathlib import Path
import sys
root = Path(sys.argv[1])
manifest = root / 'PINNED'
if manifest.exists():
    rows = manifest.read_text().splitlines()
    if not rows:
        sys.exit('empty PINNED manifest')
    for row in rows:
        expected, name = row.split(None, 1)
        path = root / name
        if hashlib.md5(path.read_bytes()).hexdigest() != expected:
            sys.exit(f'pinned library changed: {path}')

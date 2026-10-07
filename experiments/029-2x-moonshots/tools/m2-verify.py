"""Verify the staged transfer before modifying the M2 source tree."""
import hashlib
import os
from pathlib import Path
import sys
root = Path(sys.argv[1])
for row in (root / 'blobs.txt').read_text().splitlines():
    expected, name = row.split('\t', 1)
    path = root / 'src' / name
    data = os.fsencode(os.readlink(path)) if path.is_symlink() else path.read_bytes()
    actual = hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()
    if actual != expected:
        sys.exit(f'transfer hash mismatch: {name}')
print('M2 source blobs verified')

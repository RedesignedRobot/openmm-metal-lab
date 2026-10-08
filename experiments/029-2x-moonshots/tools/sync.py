"""Stage and verify Git blob hashes before updating an incremental source tree."""
import fcntl
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args], stderr=subprocess.DEVNULL)


def blob(path):
    data = os.fsencode(os.readlink(path)) if path.is_symlink() else path.read_bytes()
    return hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()


def sync(source, destination):
    source, destination = Path(source).resolve(), Path(destination).absolute()
    bench = Path('/tmp/openmm-metal-bench').resolve()
    if destination.parent.resolve() != bench or not destination.name.startswith('ultra-'):
        raise ValueError('destination must be /tmp/openmm-metal-bench/ultra-<lane>')
    if (destination / 'PINNED').exists():
        raise ValueError('refusing to change a pinned baseline')
    destination.mkdir(parents=True, exist_ok=True)
    with (destination / '.sync.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            top = Path(os.fsdecode(git(source, 'rev-parse', '--show-toplevel')).strip()).resolve()
        except subprocess.CalledProcessError:
            top = None
        if top == source:
            names = sorted(set(os.fsdecode(p) for p in git(source, 'ls-files', '-z', '--cached', '--others', '--exclude-standard').split(b'\0') if p))
            commit = git(source, 'rev-parse', 'HEAD').decode().strip()
        else:
            names = []
            for root, dirs, files in os.walk(source):
                dirs[:] = [d for d in dirs if d not in {'.git', '.codegraph', '__pycache__'}]
                for name in files + [d for d in dirs if (Path(root) / d).is_symlink()]:
                    names.append(str((Path(root) / name).relative_to(source)))
            names.sort()
            if not (source / '.commit').is_file():
                raise SystemExit('a frozen source directory must contain .commit')
            commit = (source / '.commit').read_text().strip()
            if not commit:
                raise SystemExit('empty .commit in frozen source directory')
        names = [n for n in names if n != '.commit' and os.path.lexists(source / n)]
        with tempfile.TemporaryDirectory(prefix='.stage-', dir=destination) as temporary:
            stage = Path(temporary)
            manifest = []
            for name in names:
                src, dst = source / name, stage / name
                if src.is_dir() and not src.is_symlink():
                    raise ValueError(f'unsupported submodule: {name}')
                expected = blob(src)
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(src, dst, follow_symlinks=False)
                if blob(dst) != expected or blob(src) != expected:
                    raise ValueError(f'source changed during copy: {name}')
                manifest.append((expected, name))
            for expected, name in manifest:
                if blob(source / name) != expected:
                    raise ValueError(f'source changed during staging: {name}')
            (stage / '.commit').write_text(commit + '\n')
            target = destination / 'src'
            target.mkdir(exist_ok=True)
            subprocess.run(['rsync', '-rlpc', '--delete', str(stage) + '/', str(target) + '/'], check=True)
            for expected, name in manifest:
                if blob(target / name) != expected:
                    raise ValueError(f'installed source mismatch: {name}')
            (destination / 'blobs.txt').write_text(''.join(f'{h}\t{n}\n' for h, n in manifest))
            print(f'{target}: {commit}, {len(manifest)} working-tree blobs verified')


if __name__ == '__main__':
    if len(sys.argv) != 3:
        sys.exit('usage: sync.sh <worktree or frozen snapshot> <bench dir>')
    sync(*sys.argv[1:])

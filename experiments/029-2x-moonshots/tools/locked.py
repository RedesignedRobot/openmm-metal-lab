"""Hold an advisory lock for a command; the child inherits it if the parent dies."""
import fcntl
import os
from pathlib import Path
import subprocess
import sys

path = Path(sys.argv[1])
path.parent.mkdir(parents=True, exist_ok=True)
with path.open('a') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    os.set_inheritable(lock.fileno(), True)
    sys.exit(subprocess.call(sys.argv[2:], pass_fds=(lock.fileno(),)))

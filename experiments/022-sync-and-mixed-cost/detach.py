"""Run a command in a new session, so it outlives the shell (and any process group) that started it.

usage: detach.py <log> <command...>
The command's stdout and stderr are appended to <log>; its nice value is inherited, so start this
from a shell at nice 0 (not zsh with &) when the command times anything.
"""
import os
import sys

if os.fork() == 0:
    os.setsid()
    log = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
    null = os.open(os.devnull, os.O_RDONLY)
    os.dup2(null, 0)
    os.dup2(log, 1)
    os.dup2(log, 2)
    os.execvp(sys.argv[2], sys.argv[2:])

#!/bin/sh
# Runs on the M3 Ultra: starts one command detached and prints its pid.
# usage: bg.sh <logfile> <command> [args...]
# The command runs under nohup with stdout and stderr in <logfile> and stdin from /dev/null, so it
# survives an ssh drop and holds none of ssh's fds: `ssh "$STUDIO" bg.sh ...` returns at once.
# It is plain sh, so zsh's bg_nice never renices the job (a zsh `&` over ssh gives nice 5, and
# gate.sh refuses to run at nice 5). The job inherits bg.sh's own nice, so bg.sh refuses to start
# when that isn't 0: call it in the foreground, not from a background job.
set -eu
[ $# -ge 2 ] || { echo "usage: bg.sh <logfile> <command> [args...]" >&2; exit 2; }
log="$1"
shift
[ -d "$(dirname "$log")" ] || { echo "bg.sh: no directory for $log" >&2; exit 2; }
command -v "$1" > /dev/null 2>&1 || { echo "bg.sh: cannot run $1" >&2; exit 2; }
nice_now="$(ps -o nice= -p $$ | tr -d ' ')"
[ "$nice_now" = 0 ] || { echo "bg.sh: running at nice $nice_now, not 0; call it in the foreground" >&2; exit 3; }
nohup "$@" > "$log" 2>&1 < /dev/null &
echo $!

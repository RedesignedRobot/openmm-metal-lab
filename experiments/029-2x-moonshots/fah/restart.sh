#!/bin/sh
# Restart, NaN and rollback checks for the FAH corpus, in one correctness ticket.
# Usage: restart.sh <tree> <corpus dir> <out file> [case ...]
set -u
here=$(cd "$(dirname "$0")" && pwd)
[ "$(cat /tmp/openmm-lease/pid 2>/dev/null)" = "${OPENMM_LEASE_PID:-none}" ] || [ -f "/tmp/openmm-lease/members/${OPENMM_LEASE_PID:-none}" ] ||
    exec /tmp/openmm-metal-bench/ultra-tools/lease.sh --correctness --cap 900 r2-fah "fah restart $*" /bin/sh "$here/restart.sh" "$@"
tree=$1 corpus=$2 out=$3
shift 3
[ $# -gt 0 ] || set -- neq tip3p-hmr tip4pew gbsa
for case in "$@"; do
    for precision in single mixed; do
        "$tree/venv/bin/python" "$here/restart.py" "$corpus/$case" $precision 2>&1
        "$tree/venv/bin/python" "$here/restart.py" "$corpus/$case" $precision deterministic 2>&1
    done
done > "$out"

#!/bin/sh
# Run the FAH work-unit corpus on Metal in one correctness ticket, then compare against Reference on the CPU
# after the hold ends.  Usage: run.sh <tree> <corpus dir> <out dir> [case ...]
set -u
tree=$1 corpus=$2 out=$3
here=$(cd "$(dirname "$0")" && pwd)
if ! { [ "$(cat /tmp/openmm-lease/pid 2>/dev/null)" = "${OPENMM_LEASE_PID:-none}" ] || [ -f "/tmp/openmm-lease/members/${OPENMM_LEASE_PID:-none}" ]; }; then
    /tmp/openmm-metal-bench/ultra-tools/lease.sh --correctness --cap 900 r2-fah "fah corpus $*" /bin/sh "$here/run.sh" "$@" || exit $?
    "$tree/venv/bin/python" "$here/wu.py" compare "$out"/*-single "$out"/*-mixed 2>&1 | tee "$out/compare.txt"
    exit 0
fi
shift 3
[ $# -gt 0 ] || set -- gbsa neq tip3p-hmr tip4pew
mkdir -p "$out"
for case in "$@"; do
    steps=2500
    [ "$case" = neq ] && steps=1000
    for precision in single mixed; do
        "$tree/venv/bin/python" "$here/wu.py" run "$corpus/$case" "$out/$case-$precision" $precision $steps 5 2>&1 | tail -3
    done
done

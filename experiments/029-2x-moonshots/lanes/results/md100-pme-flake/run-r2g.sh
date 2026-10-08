#!/bin/sh
# Stale-list test (head, 2026-09-27): fresh.py on r1 and int028, pme single, seed 2026, DeterministicForces,
# plus pme mixed and rf single on r1 as extra cover. One correctness ticket.
set -u
B=/tmp/openmm-metal-bench; O=$B/ultra-infra/md100-pme-r2
export PATH=$B/env/bin:$PATH
if [ $# = 0 ]; then
    exec "$B/ultra-tools/lease.sh" --correctness --cap 900 r2-infra "md100 fresh-context stale-list test" "$0" held
fi
for arm in "r1 pme single" "int028 pme single" "r1 pme mixed" "int028 pme mixed" "r1 rf single" "int028 rf single"; do
    set -- $arm
    "$B/ultra-$1/venv/bin/python" "$O/fresh.py" "$B/ultra-base/benchmarks" "$2" "$3" 2026 2>&1 | sed "s/^/$1 /"
done
echo ALL-DONE

#!/bin/sh
# Continuation of run-r2.sh (runs 1 there, one ticket each, too slow in a 7-lane queue): runs 2-6,
# alternating int028 and r1, in two correctness tickets (runs 2-4, then 5-6) of about 10 minutes each.
# usage: run-r2b.sh            (queues the tickets)
#        run-r2b.sh <first> <last>  (inside a hold)
set -u
B=/tmp/openmm-metal-bench; O=$B/ultra-infra/md100-pme-r2
export PATH=$B/env/bin:$PATH
unset PYTHONPATH
if [ $# = 0 ]; then
    "$B/ultra-tools/lease.sh" --correctness --cap 1200 r2-infra "md100 pme proof runs 2-4" "$0" 2 4
    "$B/ultra-tools/lease.sh" --correctness --cap 1200 r2-infra "md100 pme proof runs 5-6" "$0" 5 6
    echo ALL-DONE
    exit 0
fi
i=$1
while [ "$i" -le "$2" ]; do
    for arm in int028 r1; do
        "$B/ultra-$arm/venv/bin/python" "$B/ultra-tools/forces.py" --md 100 "$B/ultra-base/benchmarks" "$O/$arm-$i.txt" "$B/ultra-base/forces-md100.txt" > "$O/$arm-$i.log" 2>&1
        rc=$?
        echo "$(date -u +%H:%M:%SZ) $arm run $i exit=$rc fails=$(grep -c FAIL "$O/$arm-$i.log") pairs: $(grep -E '^(pme|apoa1pme|apoa1ljpme) ' -A1 "$O/$arm-$i.txt" | grep -o 'cutoff pairs=[0-9]*' | tr '\n' ' ')"
    done
    i=$((i+1))
done

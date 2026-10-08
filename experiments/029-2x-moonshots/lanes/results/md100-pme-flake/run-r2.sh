#!/bin/sh
# Round 2 proof of the PME cutoff-straddle reconcile: installed forces.py --md 100, all six tests in one
# process (gate conditions), 6 alternating runs on pinned int028 (7484d7bef) and ultra-r1 (8ae6cf17b),
# each in its own correctness ticket.
set -u
B=/tmp/openmm-metal-bench; O=$B/ultra-infra/md100-pme-r2
export PATH=$B/env/bin:$PATH
unset PYTHONPATH
for i in 1 2 3 4 5 6; do
    for arm in int028 r1; do
        "$B/ultra-tools/lease.sh" --correctness --cap 900 r2-infra "md100 pme proof $arm $i" \
            "$B/ultra-$arm/venv/bin/python" "$B/ultra-tools/forces.py" --md 100 "$B/ultra-base/benchmarks" "$O/$arm-$i.txt" "$B/ultra-base/forces-md100.txt" > "$O/$arm-$i.log" 2>&1
        echo "$(date -u +%H:%M:%SZ) $arm run $i exit=$? fails=$(grep -c FAIL "$O/$arm-$i.log") pairs: $(grep -E '^(pme|apoa1pme|apoa1ljpme) ' -A1 "$O/$arm-$i.txt" | grep -o 'cutoff pairs=[0-9]*' | tr '\n' ' ')"
    done
done
echo ALL-DONE

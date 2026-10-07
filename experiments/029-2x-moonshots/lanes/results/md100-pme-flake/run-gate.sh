#!/bin/sh
# md100 under exact gate conditions: unmodified forces.py, all six tests in one process, 6 alternating runs per arm.
set -u
B=/tmp/openmm-metal-bench; O=$B/ultra-lead/md100-pme
for i in 1 2 3 4 5 6; do
    for arm in int028 m29-nonbonded-final; do
        "$B/ultra-$arm/venv/bin/python" "$B/ultra-tools/forces.py" --md 100 "$B/ultra-base/benchmarks" "$O/gate-$arm-$i.txt" "$B/ultra-base/forces-md100.txt" > "$O/gate-$arm-$i.log" 2>&1
        echo "$arm run $i exit=$? $(grep -E '^pme .* single' "$O/gate-$arm-$i.txt" 2>/dev/null | tr -s ' ') | fails: $(grep -c FAIL "$O/gate-$arm-$i.txt" 2>/dev/null)"
    done
done

#!/bin/sh
# md100 pme flake check: 5 fresh processes each on pinned int028 and the nonbonded final candidate, alternating.
set -u
export PYTHONPATH=/tmp/openmm-metal-bench/ultra-tools
B=/tmp/openmm-metal-bench; O=$B/ultra-lead/md100-pme
for i in 1 2 3 4 5; do
    for arm in int028 m29-nonbonded-final; do
        "$B/ultra-$arm/venv/bin/python" "$O/forces_pme.py" --md 100 "$B/ultra-base/benchmarks" "$O/$arm-$i.txt" "$B/ultra-base/forces-md100.txt" > "$O/$arm-$i.log" 2>&1
        echo "$arm run $i exit=$? $(grep -E '^pme ' "$O/$arm-$i.txt" 2>/dev/null | tr -s ' ' | tr '\n' ';')"
    done
done

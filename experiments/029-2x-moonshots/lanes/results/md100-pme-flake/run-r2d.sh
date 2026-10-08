#!/bin/sh
# Diagnosis only, not gate conditions: pme alone (forces_pme.py = installed forces.py with TESTS = ["pme"]),
# 40 md100 runs on ultra-r1 in one correctness ticket, so failing rows leave .npz files for diag.py.
set -u
B=/tmp/openmm-metal-bench; O=$B/ultra-infra/md100-pme-r2
export PATH=$B/env/bin:$PATH
export PYTHONPATH=$B/ultra-tools
if [ $# = 0 ]; then
    exec "$B/ultra-tools/lease.sh" --correctness --cap 1200 r2-infra "md100 pme-only diagnosis r1 x40" "$0" held
fi
i=1
while [ $i -le 40 ]; do
    "$B/ultra-r1/venv/bin/python" "$O/forces_pme.py" --md 100 "$B/ultra-base/benchmarks" "$O/pmeonly/r1-$i.txt" "$B/ultra-base/forces-md100.txt" > "$O/pmeonly/r1-$i.log" 2>&1
    echo "$(date -u +%H:%M:%SZ) r1 pme-only run $i exit=$? $(grep FAIL "$O/pmeonly/r1-$i.log" | tr -s ' ')"
    i=$((i+1))
done
echo ALL-DONE

#!/bin/sh
# Is md100 pme single max|dF| a trajectory draw? pme alone, DeterministicForces=true, seeds 1-20 on
# ultra-base and on r1 (forces_det_seed_pme.py reads the seed from MD_SEED), one correctness ticket.
set -u
B=/tmp/openmm-metal-bench; O=$B/ultra-infra/md100-pme-r2
export PATH=$B/env/bin:$PATH
export PYTHONPATH=$B/ultra-tools
if [ $# = 0 ]; then
    exec "$B/ultra-tools/lease.sh" --correctness --cap 1200 r2-infra "md100 seed spread base+r1" "$0" held
fi
s=1
while [ $s -le 20 ]; do
    for arm in base r1; do
        MD_SEED=$s "$B/ultra-$arm/venv/bin/python" "$O/forces_det_seed_pme.py" --md 100 "$B/ultra-base/benchmarks" "$O/seeds/$arm-$s.txt" "$B/ultra-base/forces-md100.txt" > "$O/seeds/$arm-$s.log" 2>&1
        echo "$arm seed $s $(grep -E '^pme .*single' "$O/seeds/$arm-$s.txt" | tr -s ' ')"
    done
    s=$((s+1))
done
echo ALL-DONE

#!/bin/sh
# Integrated b69efb0fe, amber20-dhfr mixed, lm0 drift at 1e-8, 50 ps, seeds 2 and 3, with mixed's drift.py (the g2
# check's call). Run under one lease.sh --correctness hold. Output g2check-<commit>/drift-seeds.jsonl, last line
# "DHFR SEEDS DONE".
set -u
M=/tmp/openmm-metal-bench/ultra-mixed
I=/tmp/openmm-metal-bench/ultra-integrated
BENCH=/tmp/openmm-metal-bench/ultra-base/benchmarks
nice_value=$(ps -o nice= -p $$ | tr -d ' ')
[ "$nice_value" = 0 ] || { echo "running at nice $nice_value, not 0" >&2; exit 2; }
unset PYTHONPATH
grep -q "^commit b69efb0fe" $I/BUILT || { echo "integrated is not built at b69efb0fe"; exit 1; }
O=$I/g2check-b69efb0fe
for seed in 2 3; do
    line="$(cd / && $I/venv/bin/python $M/drift.py $BENCH amber20-dhfr mixed 50 $seed 1e-8 lm0)" || line="{\"error\": \"int seed $seed\"}"
    echo "{\"label\": \"int\", $(echo "$line" | cut -c2-)" | tee -a $O/drift-seeds.jsonl
done
echo "DHFR SEEDS DONE $(date -u +%H:%M:%SZ)"

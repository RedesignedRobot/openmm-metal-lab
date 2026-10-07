#!/bin/sh
# Seed spread for zero-friction LangevinMiddle drift (drift.py lm0) at 1e-8, 50 ps, amber20-dhfr mixed:
# f1 (cf1d7fc14) against t4 (5cc0ba5af), seeds 2 to 5 (seed 1 is in f1-drift.jsonl).
# Results in f1-drift-seeds.jsonl. Last line "F1 DRIFT DONE".
M=/tmp/openmm-metal-bench/ultra-mixed
BENCH=/tmp/openmm-metal-bench/ultra-base/benchmarks
nice_value=$(ps -o nice= -p $$ | tr -d ' ')
[ "$nice_value" = 0 ] || { echo "running at nice $nice_value, not 0" >&2; exit 2; }
unset PYTHONPATH
grep -q "^commit cf1d7fc14" $M/f1/BUILT || { echo "f1 is not built at cf1d7fc14"; exit 1; }
row() {
    out="$1"; label="$2"; python="$3"; shift 3
    line="$(cd / && "$python" "$@")" || line="{\"error\": \"$label $*\"}"
    echo "{\"label\": \"$label\", $(echo "$line" | cut -c2-)" | tee -a "$out"
}
for seed in 2 3 4 5; do
    for build in t4 f1; do
        row $M/f1-drift-seeds.jsonl $build $M/$build/venv/bin/python $M/drift.py $BENCH amber20-dhfr mixed 50 $seed 1e-8 lm0
    done
done
echo "F1 DRIFT DONE $(date -u +%H:%M:%SZ)"

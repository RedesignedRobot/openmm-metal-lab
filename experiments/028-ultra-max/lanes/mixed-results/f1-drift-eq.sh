#!/bin/sh
# Equilibrated NVE drift baseline (drift-eq.py): 20 ps LangevinMiddle at friction 1/ps, then 100 ps at
# friction 0, 1e-8, mixed, amber20-dhfr and gbsa, seeds 1 to 3, f1 (cf1d7fc14) against t4 (g2, 5cc0ba5af).
# Correctness only, so any nice value is fine. Results in f1-drift-eq.jsonl. Last line "F1 DRIFT EQ DONE".
M=/tmp/openmm-metal-bench/ultra-mixed
BENCH=/tmp/openmm-metal-bench/ultra-base/benchmarks
unset PYTHONPATH
grep -q "^commit cf1d7fc14" $M/f1/BUILT || { echo "f1 is not built at cf1d7fc14"; exit 1; }
row() {
    out="$1"; label="$2"; python="$3"; shift 3
    line="$(cd / && "$python" "$@")" || line="{\"error\": \"$label $*\"}"
    echo "{\"label\": \"$label\", $(echo "$line" | cut -c2-)" | tee -a "$out"
}
for seed in 1 2 3; do
    for test in amber20-dhfr gbsa; do
        for build in t4 f1; do
            row $M/f1-drift-eq.jsonl $build $M/$build/venv/bin/python $M/drift-eq.py $BENCH $test mixed 20 100 $seed 1e-8
        done
    done
done
echo "F1 DRIFT EQ DONE $(date -u +%H:%M:%SZ)"

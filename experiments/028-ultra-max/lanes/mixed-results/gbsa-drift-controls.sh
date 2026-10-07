#!/bin/sh
# Is the gbsa NVE drift Metal's or the system's? drift-eq.py on base (6df2b8bcb): 20 ps at friction 1/ps, then
# 100 ps at friction 0, 1e-8, gbsa. Arms: Metal mixed, Metal double, OpenCL mixed, CPU (mixed). Seeds are the
# outer loop, so a cap cuts seeds, never an arm. Correctness only. Results in gbsa-drift-controls.jsonl.
# Last line "GBSA CONTROLS DONE".
M=/tmp/openmm-metal-bench/ultra-mixed
BASE=/tmp/openmm-metal-bench/ultra-base
unset PYTHONPATH
grep -q "^commit 6df2b8bcb" $BASE/BUILT || { echo "base is not built at 6df2b8bcb"; exit 1; }
row() {
    label="$1"; shift
    line="$(cd / && $BASE/venv/bin/python $M/drift-eq.py $BASE/benchmarks gbsa "$@")" || line="{\"error\": \"$label $*\"}"
    echo "{\"label\": \"$label\", $(echo "$line" | cut -c2-)" | tee -a $M/gbsa-drift-controls.jsonl
}
for seed in 1 2 3; do
    row metal-mixed mixed 20 100 $seed 1e-8 Metal
    row metal-double double 20 100 $seed 1e-8 Metal
    row opencl-mixed mixed 20 100 $seed 1e-8 OpenCL
    row cpu mixed 20 100 $seed 1e-8 CPU
    echo "seed $seed done $(date -u +%H:%M:%SZ)"
done
echo "GBSA CONTROLS DONE $(date -u +%H:%M:%SZ)"

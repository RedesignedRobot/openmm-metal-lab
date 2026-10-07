#!/bin/sh
# The g2 check's shape on integrated after the f1 merge (89d7f17fc) against f1 alone (cf1d7fc14, ultra-mixed/f1), with
# mixed's bitwise.py, constraints.py and drift.py, read from ultra-mixed. Run under one lease.sh --correctness hold.
# 1. Positions and velocities after 100 steps, gbsa and rf: single must match f1 bit for bit; mixed prints the
#    largest difference.
# 2. constraints.py at 1e-8, 200 steps, pme and gbsa, mixed and single.
# 3. NVE drift with zero-friction LangevinMiddle (drift.py lm0) at 1e-8, 50 ps, amber20-dhfr and gbsa, mixed, seeds 1 to 3.
# Results in ultra-integrated/f1check-<commit>/. Last line "F1 CHECK DONE".
set -u
M=/tmp/openmm-metal-bench/ultra-mixed
I=/tmp/openmm-metal-bench/ultra-integrated
BENCH=/tmp/openmm-metal-bench/ultra-base/benchmarks
nice_value=$(ps -o nice= -p $$ | tr -d ' ')
[ "$nice_value" = 0 ] || { echo "running at nice $nice_value, not 0" >&2; exit 2; }
unset PYTHONPATH
grep -q "^commit cf1d7fc14" $M/f1/BUILT || { echo "ultra-mixed/f1 is not built at cf1d7fc14"; exit 1; }
c=$(sed -n 's/^commit //p' $I/BUILT | cut -c1-9)
O=$I/f1check-$c
mkdir -p $O/dumps
py() { case $1 in f1) echo $M/f1/venv/bin/python ;; int) echo $I/venv/bin/python ;; esac; }
row() {
    out="$1"; label="$2"; shift 2
    line="$(cd / && "$(py $label)" "$@")" || line="{\"error\": \"$label $*\"}"
    echo "{\"label\": \"$label\", $(echo "$line" | cut -c2-)" | tee -a "$out"
}
echo "$(date -u +%H:%M:%SZ) f1 check on integrated $c start"
for test in gbsa rf; do
    for precision in single mixed; do
        for build in f1 int; do
            row $O/bitwise.jsonl $build $M/bitwise.py $BENCH $test $precision 100 $O/dumps/$test-$precision-$build.npz
        done
        $M/f1/venv/bin/python $M/bitwise.py --compare $O/dumps/$test-$precision-f1.npz $O/dumps/$test-$precision-int.npz | tee -a $O/bitwise.jsonl
    done
done
for test in pme gbsa; do
    for precision in mixed single; do
        for build in f1 int; do
            row $O/constraints.jsonl $build $M/constraints.py $BENCH $test $precision 1e-8 200
        done
    done
done
for test in amber20-dhfr gbsa; do
    for seed in 1 2 3; do
        for build in f1 int; do
            row $O/drift.jsonl $build $M/drift.py $BENCH $test mixed 50 $seed 1e-8 lm0
        done
    done
done
echo "F1 CHECK DONE $(date -u +%H:%M:%SZ)"

#!/bin/sh
# Mixed's f1-check shape on integrated after the g2 merge (b69efb0fe) against t4 (g2 5cc0ba5af alone), with
# mixed's bitwise.py, constraints.py and drift.py, read from ultra-mixed. Run under one lease.sh --correctness hold.
# 1. Positions and velocities after 100 steps, gbsa and rf: single must match t4 bit for bit (the pme pair
#    only touches PME); mixed prints the largest difference.
# 2. constraints.py at 1e-8, 200 steps, pme and gbsa, mixed and single.
# 3. NVE drift with zero-friction LangevinMiddle (drift.py lm0) at 1e-8, 50 ps, amber20-dhfr and gbsa, mixed.
# Results in ultra-integrated/g2check-<commit>/. Last line "G2 CHECK DONE".
set -u
M=/tmp/openmm-metal-bench/ultra-mixed
I=/tmp/openmm-metal-bench/ultra-integrated
BENCH=/tmp/openmm-metal-bench/ultra-base/benchmarks
nice_value=$(ps -o nice= -p $$ | tr -d ' ')
[ "$nice_value" = 0 ] || { echo "running at nice $nice_value, not 0" >&2; exit 2; }
unset PYTHONPATH
grep -q "^commit 5cc0ba5af" $M/t4/BUILT || { echo "t4 is not built at 5cc0ba5af"; exit 1; }
c=$(sed -n 's/^commit //p' $I/BUILT | cut -c1-9)
O=$I/g2check-$c
mkdir -p $O/dumps
py() { case $1 in t4) echo $M/t4/venv/bin/python ;; int) echo $I/venv/bin/python ;; esac; }
row() {
    out="$1"; label="$2"; shift 2
    line="$(cd / && "$(py $label)" "$@")" || line="{\"error\": \"$label $*\"}"
    echo "{\"label\": \"$label\", $(echo "$line" | cut -c2-)" | tee -a "$out"
}
echo "$(date -u +%H:%M:%SZ) g2 check on integrated $c start"
for test in gbsa rf; do
    for precision in single mixed; do
        for build in t4 int; do
            row $O/bitwise.jsonl $build $M/bitwise.py $BENCH $test $precision 100 $O/dumps/$test-$precision-$build.npz
        done
        $M/t4/venv/bin/python $M/bitwise.py --compare $O/dumps/$test-$precision-t4.npz $O/dumps/$test-$precision-int.npz | tee -a $O/bitwise.jsonl
    done
done
for test in pme gbsa; do
    for precision in mixed single; do
        for build in t4 int; do
            row $O/constraints.jsonl $build $M/constraints.py $BENCH $test $precision 1e-8 200
        done
    done
done
for test in amber20-dhfr gbsa; do
    for build in t4 int; do
        row $O/drift.jsonl $build $M/drift.py $BENCH $test mixed 50 1 1e-8 lm0
    done
done
echo "G2 CHECK DONE $(date -u +%H:%M:%SZ)"

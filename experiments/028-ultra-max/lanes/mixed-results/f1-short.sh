#!/bin/sh
# Mixed posq/velm after 1 and 10 LangevinMiddle steps on amber20-dhfr, f1 (cf1d7fc14) against t4 (5cc0ba5af):
# the size of the per-step difference. Results in f1-bitwise.jsonl. Last line "F1 SHORT DONE".
M=/tmp/openmm-metal-bench/ultra-mixed
BENCH=/tmp/openmm-metal-bench/ultra-base/benchmarks
nice_value=$(ps -o nice= -p $$ | tr -d ' ')
[ "$nice_value" = 0 ] || { echo "running at nice $nice_value, not 0" >&2; exit 2; }
unset PYTHONPATH
grep -q "^commit cf1d7fc14" $M/f1/BUILT || { echo "f1 is not built at cf1d7fc14"; exit 1; }
test=amber20-dhfr
for steps in 1 10; do
    for build in t4 f1; do
        (cd / && $M/$build/venv/bin/python $M/bitwise.py $BENCH $test mixed $steps $M/f1-dumps/$test-mixed-$build-s$steps.npz) | tee -a $M/f1-bitwise.jsonl
    done
    $M/t4/venv/bin/python $M/bitwise.py --compare $M/f1-dumps/$test-mixed-t4-s$steps.npz $M/f1-dumps/$test-mixed-f1-s$steps.npz | tee -a $M/f1-bitwise.jsonl
done
echo "F1 SHORT DONE $(date -u +%H:%M:%SZ)"

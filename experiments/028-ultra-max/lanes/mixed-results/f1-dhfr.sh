#!/bin/sh
# posq/velm after 100 LangevinMiddle steps on amber20-dhfr, f1 (cf1d7fc14) against t4 (5cc0ba5af), single and
# mixed, t4 twice in single for repeatability. Results in f1-bitwise.jsonl. Last line "F1 DHFR DONE".
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
test=amber20-dhfr
for precision in single mixed; do
    for run in t4:a t4:b f1:a; do
        build=${run%:*}
        [ $precision = mixed ] && [ $run = t4:b ] && continue
        row $M/f1-bitwise.jsonl $build $M/$build/venv/bin/python $M/bitwise.py $BENCH $test $precision 100 \
            $M/f1-dumps/$test-$precision-${build}${run#*:}.npz
    done
    [ $precision = single ] && $M/t4/venv/bin/python $M/bitwise.py --compare $M/f1-dumps/$test-$precision-t4a.npz $M/f1-dumps/$test-$precision-t4b.npz | tee -a $M/f1-bitwise.jsonl
    $M/t4/venv/bin/python $M/bitwise.py --compare $M/f1-dumps/$test-$precision-t4a.npz $M/f1-dumps/$test-$precision-f1a.npz | tee -a $M/f1-bitwise.jsonl
done
echo "F1 DHFR DONE $(date -u +%H:%M:%SZ)"

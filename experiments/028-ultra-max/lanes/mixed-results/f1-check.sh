#!/bin/sh
# Correctness of the fused LangevinMiddle step in f1 (cf1d7fc14) against t4 (5cc0ba5af, the same constraint code
# unfused). Run under one lease.sh --correctness hold at nice 0.
# 1. Positions and velocities after 100 steps, gbsa and rf: single must match bit for bit (t4 runs twice to show the
#    run repeats); mixed prints the largest difference.
# 2. The integrator ctests (LangevinMiddle, Settle, MixedPrecision, VirtualSites, CompoundIntegrator, Checkpoints,
#    CMMotionRemover, MonteCarloBarostat), log in logs/f1-ctest.out.
# 3. constraints.py at 1e-8, 200 steps, pme and gbsa, mixed and single.
# 4. NVE drift with zero-friction LangevinMiddle (drift.py lm0) at 1e-8, 50 ps, amber20-dhfr and gbsa, mixed.
# Results: f1-bitwise.jsonl, f1-constraints.jsonl, f1-drift.jsonl. Last line "F1 CHECK DONE".
set -u
M=/tmp/openmm-metal-bench/ultra-mixed
BENCH=/tmp/openmm-metal-bench/ultra-base/benchmarks
nice_value=$(ps -o nice= -p $$ | tr -d ' ')
[ "$nice_value" = 0 ] || { echo "running at nice $nice_value, not 0" >&2; exit 2; }
unset PYTHONPATH
grep -q "^commit cf1d7fc14" $M/f1/BUILT || { echo "f1 is not built at cf1d7fc14"; exit 1; }
mkdir -p $M/f1-dumps
row() {
    out="$1"; label="$2"; python="$3"; shift 3
    line="$(cd / && "$python" "$@")" || line="{\"error\": \"$label $*\"}"
    echo "{\"label\": \"$label\", $(echo "$line" | cut -c2-)" | tee -a "$out"
}
echo "$(date -u +%H:%M:%SZ) f1 check start"
for test in gbsa rf; do
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
done
export PATH=/tmp/openmm-metal-bench/env/bin:$PATH
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
ctest --test-dir $M/f1/build -R 'TestMetal(LangevinMiddle|Settle|MixedPrecision|VirtualSites|CompoundIntegrator|Checkpoints|CMMotionRemover|MonteCarloBarostat)' \
    -j3 --timeout 600 --output-on-failure > $M/logs/f1-ctest.out 2>&1
echo "ctest: $(grep -E 'tests passed|tests failed' $M/logs/f1-ctest.out)"
for test in pme gbsa; do
    for precision in mixed single; do
        for build in t4 f1; do
            row $M/f1-constraints.jsonl $build $M/$build/venv/bin/python $M/constraints.py $BENCH $test $precision 1e-8 200
        done
    done
done
for test in amber20-dhfr gbsa; do
    for build in t4 f1; do
        row $M/f1-drift.jsonl $build $M/$build/venv/bin/python $M/drift.py $BENCH $test mixed 50 1 1e-8 lm0
    done
done
echo "F1 CHECK DONE $(date -u +%H:%M:%SZ)"

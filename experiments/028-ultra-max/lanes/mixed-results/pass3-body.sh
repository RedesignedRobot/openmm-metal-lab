#!/bin/sh
# Mixed lane pass 3: correctness of the Metal-gated tip in t5 (c1-c4 plus the gate, 6c97bd5de), all untimed and
# in parallel: constraint checks and NVE drift at 1e-8 against ultra-base with the same seeds, forces against
# Reference, and the Metal mixed ctests (Metal single and every other platform compile the base kernels).
M=/tmp/openmm-metal-bench/ultra-mixed
B=/tmp/openmm-metal-bench/ultra-base/venv/bin/python
S=$M/t5/venv/bin/python
nice_value=$(ps -o nice= -p $$ | tr -d ' ')
[ "$nice_value" = 0 ] || { echo "running at nice $nice_value, not 0" >&2; exit 2; }
export PATH=/tmp/openmm-metal-bench/env/bin:$PATH
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
echo "$(date -u +%H:%M:%SZ) pass 3 start"
grep -q '^commit 6c97bd5de' $M/t5/BUILT || { echo "t5 is not 6c97bd5de"; exit 1; }
/bin/sh $M/checks-run.sh $M/checks3.jsonl base=$B gated=$S > $M/logs/p3-checks.out 2>&1 &
for kind in vv verlet; do
    for label in base gated; do
        python=$B
        [ $label = gated ] && python=$S
        for test in gbsa amber20-dhfr; do
            DRIFT_CASES="$test 1 1e-8,$test 2 1e-8" /bin/sh $M/drift-run.sh $M/drift3-$kind.jsonl 50 $kind $label=$python \
                > $M/logs/p3-drift-$kind-$label-$test.out 2>&1 &
        done
    done
done
/tmp/openmm-metal-bench/ultra-tools/gate.sh --quick $M/t5 > $M/logs/p3-gate.out 2>&1 &
ctest --test-dir $M/t5/build -R 'TestMetal.*Mixed$' -j3 --timeout 600 --output-on-failure > $M/logs/p3-ctest-mixed.out 2>&1 &
wait
echo "$(date -u +%H:%M:%SZ) parallel part done"
ctest --test-dir $M/t5/build --rerun-failed --output-on-failure > $M/logs/p3-ctest-rerun.out 2>&1
tail -4 $M/logs/p3-ctest-rerun.out
echo "$(date -u +%H:%M:%SZ) pass 3 done"

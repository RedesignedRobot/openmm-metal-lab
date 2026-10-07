#!/bin/sh
# Mixed lane pass 4: the candidate without the SHAKE warm start (c1, c2, c4 and the Metal gate, 5cc0ba5af) in t4.
# First a screen against ultra-base, alone on the GPU (mixed, gbsa, pme and rf, 2 x 15 s). Then, untimed and in
# parallel: constraint checks and NVE drift at 1e-8 with the seeds pass 3 used for ultra-base, forces against
# Reference, and the Metal mixed ctests.
M=/tmp/openmm-metal-bench/ultra-mixed
B=/tmp/openmm-metal-bench/ultra-base/venv/bin/python
S=$M/t4/venv/bin/python
nice_value=$(ps -o nice= -p $$ | tr -d ' ')
[ "$nice_value" = 0 ] || { echo "running at nice $nice_value, not 0" >&2; exit 2; }
export PATH=/tmp/openmm-metal-bench/env/bin:$PATH
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
echo "$(date -u +%H:%M:%SZ) pass 4 start"
grep -q '^commit 5cc0ba5af' $M/t4/BUILT || { echo "t4 is not 5cc0ba5af"; exit 1; }
/tmp/openmm-metal-bench/ultra-tools/ab.sh $M/screenG2 2 15 gbsa,pme,rf base=$B:Metal:mixed g2=$S:Metal:mixed \
    > $M/logs/p4-screen.out 2>&1
echo "$(date -u +%H:%M:%SZ) screen done"
/bin/sh $M/checks-run.sh $M/checks4.jsonl g2=$S > $M/logs/p4-checks.out 2>&1 &
for kind in vv verlet; do
    for test in gbsa amber20-dhfr; do
        DRIFT_CASES="$test 1 1e-8,$test 2 1e-8" /bin/sh $M/drift-run.sh $M/drift4-$kind.jsonl 50 $kind g2=$S \
            > $M/logs/p4-drift-$kind-$test.out 2>&1 &
    done
done
/tmp/openmm-metal-bench/ultra-tools/gate.sh --quick $M/t4 > $M/logs/p4-gate.out 2>&1 &
ctest --test-dir $M/t4/build -R 'TestMetal.*Mixed$' -j3 --timeout 600 --output-on-failure > $M/logs/p4-ctest-mixed.out 2>&1 &
wait
echo "$(date -u +%H:%M:%SZ) parallel part done"
tail -3 $M/logs/p4-ctest-mixed.out
if ! grep -q ' 0 tests failed' $M/logs/p4-ctest-mixed.out; then
    ctest --test-dir $M/t4/build --rerun-failed --output-on-failure > $M/logs/p4-ctest-rerun.out 2>&1
    tail -4 $M/logs/p4-ctest-rerun.out
fi
echo "$(date -u +%H:%M:%SZ) pass 4 done"

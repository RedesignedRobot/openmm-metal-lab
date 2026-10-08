#!/bin/sh
# Mixed lane pass 1, under one lease at nice 0. First the screen, alone on the GPU: ultra-base and each
# of c1..c5 in mixed, gbsa and pme, 2 x 15 s. Then the untimed work in parallel: constraint checks, NVE
# drift (50 ps, both integrators) of ultra-base and the c1-c5 stack, forces against Reference, and the
# Metal mixed ctests of the stack.
M=/tmp/openmm-metal-bench/ultra-mixed
B=/tmp/openmm-metal-bench/ultra-base/venv/bin/python
S=$M/t5/venv/bin/python
nice_value=$(ps -o nice= -p $$ | tr -d ' ')
[ "$nice_value" = 0 ] || { echo "running at nice $nice_value, not 0" >&2; exit 2; }
export PATH=/tmp/openmm-metal-bench/env/bin:$PATH
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
echo "$(date -u +%H:%M:%SZ) pass 1 start"
# The five trees are rebuilt after a fix to c1 and c3; wait for the chain if a gap between builds let this start.
waited=0
while [ ! -f $M/rebuilt-0cad63bc2 ] && [ $waited -lt 900 ]; do sleep 10; waited=$((waited+10)); done
[ -f $M/rebuilt-0cad63bc2 ] || { echo "the rebuild chain did not finish" >&2; exit 1; }
/tmp/openmm-metal-bench/ultra-tools/ab.sh $M/screenA 2 15 gbsa,pme \
    base=$B:Metal:mixed c1=$M/venv/bin/python:Metal:mixed c2=$M/t2/venv/bin/python:Metal:mixed \
    c3=$M/t3/venv/bin/python:Metal:mixed c4=$M/t4/venv/bin/python:Metal:mixed c5=$S:Metal:mixed
echo "$(date -u +%H:%M:%SZ) screen done, census of c1-c4"
sh $M/census.sh cen4 $M/census-c4 pme mixed
echo "$(date -u +%H:%M:%SZ) correctness in parallel"
/bin/sh $M/checks-run.sh $M/checks1.jsonl base=$B stack=$S > $M/logs/p1-checks.out 2>&1 &
for kind in vv verlet; do
    for label in base stack; do
        python=$B
        [ $label = stack ] && python=$S
        for test in gbsa amber20-dhfr; do
            DRIFT_CASES="$test 1 1e-5,$test 1 1e-7,$test 2 1e-5" /bin/sh $M/drift-run.sh $M/drift-$kind.jsonl 50 $kind $label=$python \
                > $M/logs/p1-drift-$kind-$label-$test.out 2>&1 &
        done
    done
done
/tmp/openmm-metal-bench/ultra-tools/gate.sh --quick $M/t5 > $M/logs/p1-gate.out 2>&1 &
ctest --test-dir $M/t5/build -R 'TestMetal.*Mixed$' -j3 --timeout 600 --output-on-failure > $M/logs/p1-ctest-mixed.out 2>&1 &
wait
echo "$(date -u +%H:%M:%SZ) pass 1 done"

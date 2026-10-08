#!/bin/sh
# Mixed lane pass 2, whatever the arguments: TestMetalMixedPrecisionMixed on c1-c4 (it failed on c1-c5 in
# pass 1), then confirm the c1-c4 stack against ultra-base in mixed (3 x 30 s on the targeted tests), then screen
# each commit on rf (2 x 15 s), the test with water and the shortest step.
M=/tmp/openmm-metal-bench/ultra-mixed
B=/tmp/openmm-metal-bench/ultra-base/venv/bin/python
nice_value=$(ps -o nice= -p $$ | tr -d ' ')
[ "$nice_value" = 0 ] || { echo "running at nice $nice_value, not 0" >&2; exit 2; }
export PATH=/tmp/openmm-metal-bench/env/bin:$PATH
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
echo "$(date -u +%H:%M:%SZ) pass 2 start"
for t in t4; do
    ctest --test-dir $M/$t/build -R '^TestMetalMixedPrecisionMixed$' --output-on-failure > $M/logs/p2-mp-$t.out 2>&1
    echo "$t: $(grep -E 'tests passed|exception' $M/logs/p2-mp-$t.out | tr '\n' ' ')"
done
/tmp/openmm-metal-bench/ultra-tools/ab.sh $M/confirmB 3 30 gbsa,rf,pme \
    base=$B:Metal:mixed stack=$M/t4/venv/bin/python:Metal:mixed
echo "$(date -u +%H:%M:%SZ) confirmation done"
/tmp/openmm-metal-bench/ultra-tools/ab.sh $M/screenRF 2 15 rf \
    base=$B:Metal:mixed c1=$M/venv/bin/python:Metal:mixed c2=$M/t2/venv/bin/python:Metal:mixed \
    c3=$M/t3/venv/bin/python:Metal:mixed c4=$M/t4/venv/bin/python:Metal:mixed
echo "$(date -u +%H:%M:%SZ) pass 2 done"

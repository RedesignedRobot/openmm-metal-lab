#!/bin/sh
# Waits for the relaxed-math build in mm (5fbce452a), then queues its jobs: gate.sh --quick (its own correctness
# holds), the mixed precision and constant potential ctests as one correctness ticket, and two timing screens
# against ultra-base, single and mixed, each wrapped in one lease.sh.
M=/tmp/openmm-metal-bench/ultra-mixed
T=/tmp/openmm-metal-bench/ultra-tools
B=/tmp/openmm-metal-bench/ultra-base/venv/bin/python
S=$M/mm/venv/bin/python
export PATH=/tmp/openmm-metal-bench/env/bin:$PATH
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
until tail -1 $M/mm/build.out | grep -qE "^built |FAILED"; do sleep 10; done
tail -1 $M/mm/build.out | grep -q "^built " || { echo "build failed"; exit 1; }
grep -q '^commit 5fbce452a' $M/mm/BUILT || { echo "mm is not 5fbce452a"; exit 1; }
[ -e /tmp/openmm-window ] && { echo "a dedicated window is open, queueing nothing"; exit 1; }
echo "$(date -u +%H:%M:%SZ) queueing"
/bin/sh -c "nohup $T/gate.sh --quick $M/mm > $M/logs/mm-gate.out 2>&1 < /dev/null &"
/bin/sh -c "nohup $T/lease.sh --correctness ultra-mixed 'relaxed math ctests' ctest --test-dir $M/mm/build -R 'TestMetal(MixedPrecision|ConstantPotentialForce)' -j3 --timeout 600 --output-on-failure > $M/logs/mm-ctest.out 2>&1 < /dev/null &"
/bin/sh -c "nohup $T/lease.sh ultra-mixed 'relaxed math screen single' $T/ab.sh $M/screenMMs 2 15 gbsa,rf,pme base=$B:Metal:single mm=$S:Metal:single > $M/logs/mm-screen-single.out 2>&1 < /dev/null &"
/bin/sh -c "nohup $T/lease.sh ultra-mixed 'relaxed math screen mixed' $T/ab.sh $M/screenMMm 2 15 gbsa,rf,pme base=$B:Metal:mixed mm=$S:Metal:mixed > $M/logs/mm-screen-mixed.out 2>&1 < /dev/null &"
echo "$(date -u +%H:%M:%SZ) queued"

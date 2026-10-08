#!/bin/sh
# Waits for the fused LangevinMiddle build in f1 (cf1d7fc14), then queues two correctness tickets: f1-check.sh
# (bitwise, constraints, drift against t4) and the integrator ctests on f1.
M=/tmp/openmm-metal-bench/ultra-mixed
T=/tmp/openmm-metal-bench/ultra-tools
export PATH=/tmp/openmm-metal-bench/env/bin:$PATH
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
until tail -1 $M/f1-build.out | grep -qE "^built |FAILED|rror"; do sleep 10; done
tail -1 $M/f1-build.out | grep -q "^built " || { echo "build failed"; exit 1; }
grep -q '^commit cf1d7fc14' $M/f1/BUILT || { echo "f1 is not cf1d7fc14"; exit 1; }
[ -e /tmp/openmm-window ] && { echo "a dedicated window is open, queueing nothing"; exit 1; }
echo "$(date -u +%H:%M:%SZ) queueing"
/bin/sh -c "nohup $T/lease.sh --correctness ultra-mixed 'fused LangevinMiddle checks' /bin/sh $M/f1-check.sh > $M/logs/f1-check.out 2>&1 < /dev/null &"
/bin/sh -c "nohup $T/lease.sh --correctness ultra-mixed 'fused LangevinMiddle ctests' ctest --test-dir $M/f1/build -R 'TestMetal(LangevinMiddle|Settle|MixedPrecision|VirtualSites|CompoundIntegrator|Checkpoints|CMMotionRemover|MonteCarloBarostat)' -j3 --timeout 600 --output-on-failure > $M/logs/f1-ctest.out 2>&1 < /dev/null &"
echo "$(date -u +%H:%M:%SZ) queued"

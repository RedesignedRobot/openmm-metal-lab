#!/bin/sh
# Integrated after the f1 merge: build.sh, then the full gate and the f1 check as two correctness
# tickets. Pids go to int-chain.pids so they can be stopped by pid.
B=/tmp/openmm-metal-bench
I=$B/ultra-integrated
echo "$(date -u +%H:%M:%SZ) build.sh $I"
$B/ultra-tools/build.sh $I > $I/build.out 2>&1 || { echo "BUILD FAILED"; tail -20 $I/build.out; exit 1; }
c=$(sed -n 's/^commit //p' $I/BUILT | cut -c1-9)
echo "$(date -u +%H:%M:%SZ) built $c"
cd /
nohup $B/ultra-tools/gate.sh $I > $I/gate-full-$c.out 2>&1 < /dev/null &
echo "gate $!" | tee $B/ultra-infra/int-chain.pids
nohup $B/ultra-tools/lease.sh --correctness --cap 2700 ultra-integrated "infra: f1 check (bitwise, constraints, lm0 drift seeds 1-3) on integrated $c against f1" \
    /bin/sh $B/ultra-infra/int-f1-check.sh > $I/f1check-$c.out 2>&1 < /dev/null &
echo "f1check $!" | tee -a $B/ultra-infra/int-chain.pids

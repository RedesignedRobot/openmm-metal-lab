#!/bin/sh
# Integrated after the g2 merge: build.sh, then the full gate and the g2 check as two correctness
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
nohup $B/ultra-tools/lease.sh --correctness --cap 2700 ultra-integrated "infra: g2 check (bitwise, constraints, lm0 drift) on integrated $c against t4" \
    /bin/sh $B/ultra-infra/int-g2-check.sh > $I/g2check-$c.out 2>&1 < /dev/null &
echo "g2check $!" | tee -a $B/ultra-infra/int-chain.pids

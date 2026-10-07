#!/bin/sh
# Integrated at 17929e631 (the pme pair): build.sh, then the full gate and detforces as two
# correctness tickets. Pids go to int-chain.pids so they can be stopped by pid.
B=/tmp/openmm-metal-bench
I=$B/ultra-integrated
echo "$(date -u +%H:%M:%SZ) build.sh $I"
$B/ultra-tools/build.sh $I > $I/build.out 2>&1 || { echo "BUILD FAILED"; tail -20 $I/build.out; exit 1; }
c=$(sed -n 's/^commit //p' $I/BUILT | cut -c1-9)
echo "$(date -u +%H:%M:%SZ) built $c"
cd /
nohup $B/ultra-tools/gate.sh $I > $I/gate-full-$c.out 2>&1 < /dev/null &
echo "gate $!" | tee $B/ultra-infra/int-chain.pids
nohup $B/ultra-tools/lease.sh --correctness ultra-integrated "infra: detforces on integrated $c" \
    $I/venv/bin/python $B/ultra-infra/next/detforces.py $B/ultra-base/benchmarks $I/detforces-$c.txt \
    > $I/detforces-$c.out 2>&1 < /dev/null &
echo "detforces $!" | tee -a $B/ultra-infra/int-chain.pids

#!/bin/sh
# Integrated after the batch3 merge (sort2, tiles4, xres, cut): build.sh, then the full gate as a
# merge-path ticket. The gate's pid goes to int-chain4.pids so it can be stopped by pid.
B=/tmp/openmm-metal-bench
I=$B/ultra-integrated
echo "$(date -u +%H:%M:%SZ) build.sh $I"
$B/ultra-tools/build.sh $I > $I/build.out 2>&1 || { echo "BUILD FAILED"; tail -20 $I/build.out; exit 1; }
c=$(sed -n 's/^commit //p' $I/BUILT | cut -c1-9)
echo "$(date -u +%H:%M:%SZ) built $c"
cd /
nohup $B/ultra-tools/gate.sh --merge-path $I > $I/gate-full-$c.out 2>&1 < /dev/null &
echo "gate $!" | tee $B/ultra-infra/int-chain4.pids

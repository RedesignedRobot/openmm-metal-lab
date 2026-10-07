#!/bin/sh
# r3-lanes: wait for the build, quick gate, correctness (md100, detforces, PME ctests), then one shader screen of apoa1pme mixed.
set -u
T=/tmp/openmm-metal-bench/ultra-tools
D=/tmp/openmm-metal-bench/ultra-r3-lanes
export AB_LANE=r2-spread
$T/build.sh $D > $D/build.out 2>&1
[ -f $D/BUILT ] || { echo "build failed"; tail -30 $D/build.out; exit 1; }
echo "== build ok $(date -u +%H:%M)Z"
$T/gate.sh --quick $D > $D/gate.out 2>&1; g=$?; tail -5 $D/gate.out; echo "gate exit=$g"
[ $g -eq 0 ] || exit 1
$T/lease.sh --correctness r2-spread "r3-lanes md100 detforces ctest" $D/check.sh > $D/check.out 2>&1; echo "check exit=$?"; grep "exit=" $D/check.out
$T/lease.sh r2-spread "r3-lanes shader screen apoa1pme mixed" $D/census.sh > $D/census.out 2>&1; echo "census exit=$? $(date -u +%H:%M)Z"
P=/tmp/openmm-metal-bench/env/bin/python3; C=$HOME/code/metal/lab/experiments/029-2x-moonshots/lanes/results/r2-spread/census-tools
$P $C/dist.py $D/census/mixed-apoa1pme-intervals.xml $(cat $D/census/mixed-apoa1pme.pypid) gridInterpolateForce computeNonbonded
$P $C/wall.py $D/census/mixed-apoa1pme-intervals.xml $(cat $D/census/mixed-apoa1pme.pypid) | head -14
$P $C/dist.py $D/census/base-mixed-apoa1pme-intervals.xml $(cat $D/census/base-mixed-apoa1pme.pypid) gridInterpolateForce computeNonbonded
$P $C/wall.py $D/census/base-mixed-apoa1pme-intervals.xml $(cat $D/census/base-mixed-apoa1pme.pypid) | head -14

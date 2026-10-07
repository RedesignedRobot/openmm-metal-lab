#!/bin/sh
# r3-interp: sync and build after 07:00Z, quick gate, md100/detforces/ctest, then 3x30 confirms against ultra-integrated (6f6320bcd), one screen per test.
set -u
T=/tmp/openmm-metal-bench/ultra-tools
D=/tmp/openmm-metal-bench/ultra-r3-interp
P=/tmp/openmm-metal-bench/ultra-integrated
export AB_LANE=r2-spread
M=/tmp/openmm-metal-bench/ultra-r2-pmefft/mb
if [ "$(date -u +%H)" -lt 7 ]; then echo "$(date -u +%H:%M)Z night slot, skipped"; exit 1; fi
$T/sync.sh $HOME/code/wt/r3-interp $D || exit 1
cp $M/r3check.sh $D/check.sh
$T/build.sh $D > $D/build.out 2>&1 || { echo "build failed"; tail -30 $D/build.out; exit 1; }
echo "== build ok $(date -u +%H:%M)Z"
$T/gate.sh --quick $D > $D/gate.out 2>&1; g=$?; tail -5 $D/gate.out; echo "gate exit=$g"
[ $g -eq 0 ] || exit 1
$T/lease.sh --correctness r2-spread "r3-interp md100 detforces ctest" $D/check.sh > $D/check.out 2>&1; echo "check exit=$?"; grep "exit=" $D/check.out
cfg="mine-single=$D/venv/bin/python:Metal:single base-single=$P/venv/bin/python:Metal:single mine-mixed=$D/venv/bin/python:Metal:mixed base-mixed=$P/venv/bin/python:Metal:mixed"
for t in pme amber20-dhfr apoa1pme apoa1ljpme amber20-cellulose amber20-stmv; do
  $T/ab.sh $D/c-$t 3 30 $t $cfg > $D/c-$t.out 2>&1; echo "$t exit=$? $(date -u +%H:%M)Z"
  /tmp/openmm-metal-bench/env/bin/python $T/summarize.py $D/c-$t mine/base
done

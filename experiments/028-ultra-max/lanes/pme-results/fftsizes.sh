#!/bin/sh
# usage: fftsizes.sh test reps sizes...   Recip-group time with only the two FFTs running, per grid size.
L=/tmp/openmm-metal-bench/ultra-pme
t=$1; reps=$2; shift 2
for n in "$@"; do
  echo "== grid $n"
  PMEPROF_GRID=$n PME_LAB_SKIP=spread,conv,interp /bin/sh $L/env.sh $L $L/pmeprof.py $L/bench $t single $reps 2>&1 | grep "^load\|recip-empty\|Error"
done

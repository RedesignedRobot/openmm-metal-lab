#!/bin/sh
# usage: profskip.sh ROOT test prec reps   Subtractive PME profile: recip-group time with each stage skipped.
L=/tmp/openmm-metal-bench/ultra-pme
for skip in none index spread fwd conv inv interp spread,fwd,conv,inv,interp,index; do
  echo "== skip $skip nosort=${PME_LAB_NOSORT:-0}"
  PME_LAB_SKIP=$skip /bin/sh $L/env.sh $1 $L/pmeprof.py $L/bench $2 $3 $4 2>&1 | grep "^load\\|recip-empty"
done

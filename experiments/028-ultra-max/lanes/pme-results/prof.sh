#!/bin/sh
# usage: prof.sh BUILD_ROOT "tests" "precisions" reps
L=/tmp/openmm-metal-bench/ultra-pme
for t in $2; do for p in $3; do
  /bin/sh $L/env.sh $1 $L/pmeprof.py $L/bench $t $p $4 2>&1 | grep -v Warning
done; done

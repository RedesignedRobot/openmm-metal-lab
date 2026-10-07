#!/bin/sh
# probe9: findBlockBounds variants, sampled shader timeline, one ticket at a time.
set -u
T=/tmp/openmm-metal-bench/ultra-r2-accum-nb-p
O=/tmp/openmm-metal-bench/ultra-r2-accum-nb/probe9
C=/tmp/openmm-metal-bench/ultra-r2-accum-nb/chk/shader-fbb.sh
mkdir -p $O
for test in apoa1rf amber20-cellulose; do
  for arm in "base 0 32" "par 1 32" "par128 1 128" "par256 1 256"; do
    set -- $arm
    P_FBB=$2 P_FBBG=$3 $C $O $1-$test $test $T 2 || echo "arm $1 $test failed"
    rm -rf $O/$1-$test.trace
  done
done
echo probe9 done

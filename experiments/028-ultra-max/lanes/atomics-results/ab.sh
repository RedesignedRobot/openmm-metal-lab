#!/bin/sh
# A/B screen of Metal plugin variants. Usage: ab.sh OUTDIR ROUNDS SECONDS PRECISION TESTS VARIANT...
# Each VARIANT is a plugin dir name under $L (plugins-<name>); order reverses every other round.
set -e
L=/tmp/openmm-metal-bench/ultra-atomics
OUT=$1; ROUNDS=$2; SECS=$3; PREC=$4; TESTS=$5; shift 5
[ "$(ps -o nice= -p $$ | tr -d ' ')" = "0" ] || { echo "nice is not 0, refusing"; exit 1; }
mkdir -p $OUT
export PYTHONPATH=$L/build/python/build/lib.macosx-11.0-arm64-cpython-313
export DYLD_LIBRARY_PATH=$L/prefix/lib
cd $L/src/examples/benchmarks
r=0
while [ $r -lt $ROUNDS ]; do
  if [ $((r % 2)) -eq 0 ]; then ORDER="$*"; else ORDER=$(echo "$*" | awk '{for(i=NF;i>0;i--) printf "%s ", $i}'); fi
  for t in $(echo $TESTS | tr ',' ' '); do
    for v in $ORDER; do
      echo "round=$r test=$t variant=$v load=$(sysctl -n vm.loadavg) utc=$(date -u +%H:%M:%S)" >> $OUT/log
      OPENMM_PLUGIN_DIR=$L/plugins-$v /tmp/openmm-metal-bench/env/bin/python $L/src/examples/benchmarks/benchmark.py --platform Metal --precision $PREC --test $t --seconds $SECS --verbose > $OUT/r$r-$t-$v.txt 2>&1 || echo "FAILED r$r $t $v" >> $OUT/log
      tail -1 $OUT/r$r-$t-$v.txt >> $OUT/log
    done
  done
  r=$((r+1))
done
echo DONE >> $OUT/log

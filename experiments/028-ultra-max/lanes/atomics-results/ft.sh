#!/bin/sh
# Force-eval timing across plugin variants. Usage: ft.sh OUTFILE ROUNDS PRECISION STEPS TESTS VARIANT...
# Runs under the GPU lease (lease.sh); order reverses every other round.
L=/tmp/openmm-metal-bench/ultra-atomics
[ -n "${OPENMM_LEASE_PID:-}" ] || exec /tmp/openmm-metal-bench/ultra-tools/lease.sh atomics "force-eval timing $*, <20 min" "$0" "$@"
OUT=$1; ROUNDS=$2; PREC=$3; STEPS=$4; TESTS=$5; shift 5
[ "$(ps -o nice= -p $$ | tr -d ' ')" = "0" ] || { echo "nice is not 0, refusing" > $OUT; exit 1; }
export PYTHONPATH=$L/build/python/build/lib.macosx-11.0-arm64-cpython-313
export DYLD_LIBRARY_PATH=$L/prefix/lib
cd $L/src/examples/benchmarks
r=0
while [ $r -lt $ROUNDS ]; do
  if [ $((r % 2)) -eq 0 ]; then ORDER="$*"; else ORDER=$(echo "$*" | awk '{for(i=NF;i>0;i--) printf "%s ", $i}'); fi
  for t in $(echo $TESTS | tr ',' ' '); do
    for v in $ORDER; do
      echo "round=$r variant=$v load=$(sysctl -n vm.loadavg)" >> $OUT
      OPENMM_PLUGIN_DIR=$L/plugins-$v /tmp/openmm-metal-bench/env/bin/python $L/forcetime.py $t $PREC $STEPS 5 >> $OUT 2>&1 || echo "FAILED $t $v" >> $OUT
    done
  done
  r=$((r+1))
done
echo DONE >> $OUT

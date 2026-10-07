#!/bin/sh
# Dump forces for each plugin variant under the GPU lease. Usage: dumprun.sh VARIANT...
L=/tmp/openmm-metal-bench/ultra-atomics
export PYTHONPATH=$L/build/python/build/lib.macosx-11.0-arm64-cpython-313
export DYLD_LIBRARY_PATH=$L/prefix/lib
cd $L/src/examples/benchmarks
for v in "$@"; do
  OPENMM_PLUGIN_DIR=$L/plugins-$v /tmp/openmm-metal-bench/env/bin/python $L/dumpforces.py $L/forces-$v.npz > $L/dump-$v.log 2>&1 || echo "FAILED $v" >> $L/dump-$v.log
done
echo DONE > $L/dump.done

#!/bin/sh
# Screen plugins-b0 (71a602b43) against plugins-bonded (d8ab45b2b), 2 rounds of 15 s.
# usage: screen2.sh OUTDIR TESTS.  Refuses to run unless bb.sh finished and both plugins still match its md5s.
L=/tmp/openmm-metal-bench/ultra-atomics
grep -q "^bb done" $L/bb.out || { echo "bb.sh did not finish"; exit 1; }
for v in b0 bonded; do
  grep -q "^$v $(md5 -q $L/plugins-$v/libOpenMMMetal.dylib) " $L/bb.out || { echo "plugins-$v changed since bb.sh"; exit 1; }
done
P=$L/venv/bin/python:Metal:single:OPENMM_PLUGIN_DIR=$L/plugins
exec /tmp/openmm-metal-bench/ultra-tools/ab.sh $1 2 15 $2 b0=$P-b0 bonded=$P-bonded

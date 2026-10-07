#!/bin/sh
# Screen words (4be61f9b6, the lane prefix) against ultra-base (6df2b8bcb) and p0 (71a602b43's nonbonded files in
# the words tree), 2 rounds of 15 s. p0 isolates words: ultra-base lacks 71a602b43's PME spreading change.
# usage: wscreen.sh OUTDIR TESTS.  Refuses to run if either lane plugin changed since 22:30Z.
L=/tmp/openmm-metal-bench/ultra-atomics
[ "$(md5 -q $L/prefix/lib/plugins/libOpenMMMetal.dylib)" = 978e3bbcdf338f697ba8fcd6a5076d9b ] || { echo "words plugin changed"; exit 1; }
[ "$(md5 -q $L/plugins-p0/libOpenMMMetal.dylib)" = 5582c317c405f72d18b435fe5408fb44 ] || { echo "p0 plugin changed"; exit 1; }
P=$L/venv/bin/python:Metal:single
exec /tmp/openmm-metal-bench/ultra-tools/ab.sh $1 2 15 $2 base=/tmp/openmm-metal-bench/ultra-base/venv/bin/python:Metal:single p0=$P:OPENMM_PLUGIN_DIR=$L/plugins-p0 words=$P

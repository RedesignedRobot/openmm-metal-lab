#!/bin/sh
# Confirm screen: plugins-b0 (71a602b43, p0) against plugins-floor (1a29563d1, chunked bonded with the 10,000-term floor), 3 rounds of 30 s.
# usage: screen3.sh OUTDIR TESTS.  Refuses to run if either plugin changed since it was built.
L=/tmp/openmm-metal-bench/ultra-atomics
[ "$(md5 -q $L/plugins-b0/libOpenMMMetal.dylib)" = 705772246ae63f543cba330b95ae6eb5 ] || { echo "plugins-b0 changed"; exit 1; }
[ "$(md5 -q $L/plugins-floor/libOpenMMMetal.dylib)" = 4efa4b20a54e6effe5c5c65f2ac4510b ] || { echo "plugins-floor changed"; exit 1; }
echo "timing plugins-b0 md5 $(md5 -q $L/plugins-b0/libOpenMMMetal.dylib), plugins-floor md5 $(md5 -q $L/plugins-floor/libOpenMMMetal.dylib), core libs from $L/prefix: $(head -1 $L/BUILT)"
P=$L/venv/bin/python:Metal:single:OPENMM_PLUGIN_DIR=$L/plugins
exec /tmp/openmm-metal-bench/ultra-tools/ab.sh $1 3 30 $2 p0=$P-b0 floor=$P-floor

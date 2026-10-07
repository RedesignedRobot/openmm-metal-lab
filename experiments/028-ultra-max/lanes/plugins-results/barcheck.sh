#!/bin/sh
# Runs on the M3 Ultra under lease.sh --correctness: the AMOEBA ctests, then amoebaforces.sh, for one build.
# usage: barcheck.sh <label> <dir>
[ "$(ps -o nice= -p $$ | tr -d ' ')" = 0 ] || { echo "refusing to run at nice $(ps -o nice= -p $$)"; exit 1; }
export PATH=/tmp/openmm-metal-bench/env/bin:$PATH
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
unset PYTHONPATH
L=/tmp/openmm-metal-bench/ultra-plugins
echo "ctest $1 $(sed -n 's/^commit //p' $2/BUILT) $(date -u +%H:%M:%SZ)"
ctest --test-dir "$2/build" -R TestMetalAmoeba --timeout 600 --output-on-failure -j2
echo "ctest exit $? $(date -u +%H:%M:%SZ)"
$L/amoebaforces.sh "$1" "$2"

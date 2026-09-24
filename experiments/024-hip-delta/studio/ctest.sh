#!/bin/sh
# Runs on the Studio: the Metal tests of one tree, with the elapsed time.
# usage: ctest.sh <tree> <label>
D=/tmp/openmm-metal-bench/hipdelta
export PATH=/tmp/openmm-metal-bench/env/bin:$PATH
cd "$D/$1/build"
start=$(date +%s)
ctest -R TestMetal -j2 --timeout 600 > "$D/ctest-$2.txt" 2>&1
echo "elapsed $(( $(date +%s) - start )) s" >> "$D/ctest-$2.txt"
tail -4 "$D/ctest-$2.txt"

#!/bin/sh
# 028 nonbonded lane: DeterministicForces bitwise check, x-resident 761d5a666 against 6d72c3ae9, 5 fresh contexts each.
D=/tmp/openmm-metal-bench/ultra-nonbonded
X=/tmp/openmm-metal-bench/ultra-nonbonded-xres
grep -q 6d72c3ae9 $D/BUILT || { echo "build of 6d72c3ae9 not ready"; exit 1; }
grep -q 761d5a666 $X/BUILT || { echo "build of 761d5a666 not ready"; exit 1; }
set -e
$D/venv/bin/python $D/bitcheck.py $D/bits/tiles 5
$X/venv/bin/python $D/bitcheck.py $D/bits/xres 5
$D/venv/bin/python $D/bitcheck.py --compare $D/bits/tiles $D/bits/xres

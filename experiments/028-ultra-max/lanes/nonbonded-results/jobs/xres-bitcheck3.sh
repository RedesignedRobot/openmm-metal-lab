#!/bin/sh
# 028 nonbonded lane: DeterministicForces bitwise check of x-resident 761d5a666 in 3 separate processes, each one
# compared against the 6d72c3ae9 forces that xres-bitcheck.sh saved in bits/tiles.
D=/tmp/openmm-metal-bench/ultra-nonbonded
X=/tmp/openmm-metal-bench/ultra-nonbonded-xres
grep -q 761d5a666 $X/BUILT || { echo "build of 761d5a666 not ready"; exit 1; }
set -e
for p in 1 2 3; do $X/venv/bin/python $D/bitcheck.py $D/bits3/p$p 1; done
for p in 1 2 3; do echo "process $p:"; $D/venv/bin/python $D/bitcheck.py --compare $D/bits/tiles $D/bits3/p$p; done

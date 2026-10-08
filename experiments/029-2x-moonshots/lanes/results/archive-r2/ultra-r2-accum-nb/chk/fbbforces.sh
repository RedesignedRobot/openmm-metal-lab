#!/bin/sh
# probe9 correctness: forces gate for par (32) and par256 variants in tree p.
cd /tmp/openmm-metal-bench/ultra-r2-accum-nb-p || exit 1
O=/tmp/openmm-metal-bench/ultra-r2-accum-nb/probe9
mkdir -p $O
P_FBB=1 P_FBBG=256 venv/bin/python ../ultra-tools/forces.py ../ultra-base/benchmarks $O/forces-par256.txt ../ultra-base/forces.txt; echo "par256 exit $?"
P_FBB=1 P_FBBG=32 venv/bin/python ../ultra-tools/forces.py ../ultra-base/benchmarks $O/forces-par.txt ../ultra-base/forces.txt; echo "par exit $?"

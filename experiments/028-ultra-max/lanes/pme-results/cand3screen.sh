#!/bin/sh
# usage: cand3screen.sh 1|2|3   Run inside one lease.sh hold each. cand3 is 5bfc934b6 (PME in its own pass plus the
# force fold, on with 16 or more cores), screened against cand2 (17929e631, its parent), 2 x 15 s interleaved.
# Timing only: forces are checked by cand3's full gate, queued once the screen clears 3%.
# Part 1: pme, apoa1pme, apoa1ljpme and amber20-dhfr single. Part 2: amber20-cellulose and amber20-stmv single.
# Part 3: pme, apoa1pme and apoa1ljpme mixed.
L=/tmp/openmm-metal-bench/ultra-pme
T=/tmp/openmm-metal-bench/ultra-tools
C=$L/cand3
( cd $C/src && git hash-object platforms/common/include/openmm/common/CommonCalcNonbondedForce.h platforms/common/src/CommonCalcNonbondedForce.cpp platforms/common/src/kernels/pme.cc platforms/metal/include/MetalKernels.h platforms/metal/include/MetalQueue.h platforms/metal/src/MetalContext.cpp platforms/metal/src/MetalKernels.cpp platforms/metal/src/MetalQueue.cpp ) | diff - $L/cand3hash.txt || { echo "cand3 src does not match 5bfc934b6"; exit 1; }
echo "cand3 src matches 5bfc934b6; BUILT $(sed -n 's/^built //p' $C/BUILT); load $(sysctl -n vm.loadavg) at $(date -u +%H:%M:%SZ)"
case "$1" in
1) $T/ab.sh $L/ab-cand3-s1 2 15 pme,apoa1pme,apoa1ljpme,amber20-dhfr cand2=$L/cand2/venv/bin/python:Metal:single cand3=$C/venv/bin/python:Metal:single ;;
2) $T/ab.sh $L/ab-cand3-s2 2 15 amber20-cellulose,amber20-stmv cand2=$L/cand2/venv/bin/python:Metal:single cand3=$C/venv/bin/python:Metal:single ;;
3) $T/ab.sh $L/ab-cand3-mixed 2 15 pme,apoa1pme,apoa1ljpme cand2=$L/cand2/venv/bin/python:Metal:mixed cand3=$C/venv/bin/python:Metal:mixed ;;
esac
echo "done $(date -u +%H:%M:%SZ)"

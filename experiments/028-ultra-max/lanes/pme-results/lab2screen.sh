#!/bin/sh
# usage: lab2screen.sh   One lease hold, about 14 minutes, timing only. lab2 is bf09b5e99: cand3 (5bfc934b6) plus two
# knobs. PME_LAB_DISP_GRIDS gives the LJPME dispersion chain grids of its own and ends the pass between the two chains,
# so Metal may run the Coulomb and dispersion chains side by side (LJPME only). PME_LAB_SPLIT_BONDED puts bonded forces
# in a pass of their own, so they may run beside the list build and the PME pass. 2 x 15 s interleaved, single:
# apoa1ljpme with cand3, dispg and bsplit, then pme and apoa1pme with cand3 and bsplit. Forces of a winning knob are
# checked by its production form's gate.
L=/tmp/openmm-metal-bench/ultra-pme
R=$L/lab2
( cd $R/src && git hash-object platforms/common/include/openmm/common/CommonCalcNonbondedForce.h platforms/common/include/openmm/common/ComputeQueue.h platforms/common/src/CommonCalcNonbondedForce.cpp platforms/metal/src/MetalKernels.cpp platforms/metal/src/MetalQueue.cpp ) | diff - $L/lab2hash.txt || { echo "lab2 src does not match bf09b5e99"; exit 1; }
grep -q bf09b5e99 $R/BUILT || { echo "lab2 is not built at bf09b5e99"; exit 1; }
echo "lab2 src matches bf09b5e99; BUILT $(sed -n 's/^built //p' $R/BUILT); load $(sysctl -n vm.loadavg) at $(date -u +%H:%M:%SZ)"
/tmp/openmm-metal-bench/env/bin/python $L/ab.py 2 15 apoa1ljpme single cand3=$R "dispg=$R::PME_LAB_DISP_GRIDS=1" "bsplit=$R::PME_LAB_SPLIT_BONDED=1"
/tmp/openmm-metal-bench/env/bin/python $L/ab.py 2 15 pme,apoa1pme single cand3=$R "bsplit=$R::PME_LAB_SPLIT_BONDED=1"
echo "done $(date -u +%H:%M:%SZ)"

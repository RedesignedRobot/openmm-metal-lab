#!/bin/sh
# usage: spreadvar.sh   One lease hold, about 16 minutes: 2 x 15 s interleaved benchmark.py screen of ultra-base against
# the lab tree (which runs as 17929e631 with no knobs set), the PME stream, the tiled spread under MSL 4.1 (256 threads,
# one atom each), the tiled spread with one thread per (atom, z offset) in 1024-thread groups, and the default spread
# launched as 256-thread groups with one work item per thread. The tiled spread's forces match the default spread to
# 2e-6 on the M2, so its force check waits until it wins on time.
L=/tmp/openmm-metal-bench/ultra-pme
( cd $L/src && git hash-object platforms/common/src/kernels/pme.cc platforms/common/src/CommonCalcNonbondedForce.cpp platforms/metal/src/MetalContext.cpp platforms/metal/src/MetalFFT3D.cpp ) | diff - $L/labhash.txt && echo "lab src matches labhash.txt; BUILT $(ls -l $L/BUILT | awk '{print $6, $7, $8}')"
echo "load $(sysctl -n vm.loadavg) at $(date -u +%H:%M:%SZ)"
ps -axo pcpu,command -r | head -5 | cut -c1-120
/tmp/openmm-metal-bench/env/bin/python $L/ab.py 2 15 apoa1pme,pme,apoa1ljpme single ubase=/tmp/openmm-metal-bench/ultra-base lab=$L stream=$L:DisablePmeStream=false "tiled41=$L::PME_LAB_TILED=1;PME_LAB_MSL41=1" "ti1024=$L::PME_LAB_TILED=1;PME_LAB_MSL41=1;PME_LAB_TILE_ITEMS=1;PME_LAB_TILE_BLOCK=1024" "b256m5=$L::PME_LAB_BLOCK=256;PME_LAB_SPREAD_MUL=5"
# The PME share of a force evaluation now: reciprocal group alone, direct group alone, and both, on ultra-base and the lab tree.
for t in apoa1pme apoa1ljpme; do
  for R in /tmp/openmm-metal-bench/ultra-base $L; do
    echo "== pmeprof $t $R"
    /bin/sh $L/env.sh $R $L/pmeprof.py $L/bench $t single 50 2>&1 | grep "recip-empty\|rror"
  done
done
# Spread cost split on apoa1pme: plain (non-atomic) adds, no grid writes at all, and the two tiled kernels.
for v in PME_LAB_PLAIN=1 PME_LAB_NOWRITE=1 "PME_LAB_TILED=1 PME_LAB_MSL41=1" "PME_LAB_TILED=1 PME_LAB_MSL41=1 PME_LAB_TILE_ITEMS=1 PME_LAB_TILE_BLOCK=1024"; do
  echo "== pmeprof apoa1pme lab $v"
  env $v /bin/sh $L/env.sh $L $L/pmeprof.py $L/bench apoa1pme single 50 2>&1 | grep "recip-empty\|rror"
done

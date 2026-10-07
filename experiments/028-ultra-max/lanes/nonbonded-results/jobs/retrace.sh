#!/bin/sh
# 028 nonbonded lane: Metal shader timeline of rf, then apoa1rf, on the merged integrated stack (sort2, tiles4, xres),
# with profiler's shader.sh unchanged. The OpenCL side reuses profiler's rf-opencl trace from 88658 (ultra-base; the
# merged commits don't touch OpenCL). Run it under lease.sh as one hold.
I=/tmp/openmm-metal-bench/ultra-integrated
O=/tmp/openmm-metal-bench/ultra-nonbonded/shader
S=/tmp/openmm-metal-bench/ultra-profiler/tools/shader.sh
commit=$(sed -n 's/^commit //p' $I/BUILT)
echo "integrated BUILT $commit"
$S $O rf-int rf $I 1
$S $O apoa1rf-int apoa1rf $I 1 rf-int

#!/bin/sh
# M0(1), one timing hold: OpenCL shader-timeline census of ultra-r1 on all nine tests (1 s of prof.py each,
# single), then Metal amber20-stmv single, which r2-mixed's Metal census (ultra-r2-mixed/census) lacks.
# usage: lease.sh r2-infra "M0 OpenCL census" census-ocl.sh
set -u
out=/tmp/openmm-metal-bench/ultra-infra/m0/ocl
tree=/tmp/openmm-metal-bench/ultra-r1
export SHADER_HELD=1 PRECISION=single
for test in gbsa rf pme amber20-dhfr apoa1rf apoa1pme apoa1ljpme amber20-cellulose amber20-stmv; do
    PLATFORM=OpenCL /tmp/openmm-metal-bench/ultra-tools/shader.sh "$out" "$test-opencl" "$test" "$tree" 1 || echo "failed $test opencl"
done
PLATFORM=Metal /tmp/openmm-metal-bench/ultra-tools/shader.sh "$out" "amber20-stmv-metal" amber20-stmv "$tree" 1 || echo "failed stmv metal"
echo "census done $(date -u +%H:%M:%SZ)"

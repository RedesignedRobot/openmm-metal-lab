#!/bin/sh
set -u
export SHADER_HELD=1 PRECISION=single SAVE_WAIT=420 PLATFORM=OpenCL
/tmp/openmm-metal-bench/ultra-tools/shader.sh /tmp/openmm-metal-bench/ultra-infra/m0/ocl amber20-stmv-opencl amber20-stmv /tmp/openmm-metal-bench/ultra-r1 1 || echo "failed stmv opencl"
echo "stmv done $(date -u +%H:%M:%SZ)"

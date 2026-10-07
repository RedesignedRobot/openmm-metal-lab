#!/bin/sh
# One timing hold: shader timelines of apoa1pme on ultra-day-trial, Metal mixed and single, plus OpenCL single for the 2x yardstick.
export SHADER_HELD=1
T=/tmp/openmm-metal-bench/ultra-tools
O=/tmp/openmm-metal-bench/ultra-r3-interp/census
B=/tmp/openmm-metal-bench/ultra-day-trial
PRECISION=mixed $T/shader.sh $O mixed-apoa1pme apoa1pme $B 2 || echo "failed mixed"
PRECISION=single $T/shader.sh $O single-apoa1pme apoa1pme $B 2 || echo "failed single"
PRECISION=single PLATFORM=OpenCL $T/shader.sh $O ocl-apoa1pme apoa1pme $B 2 || echo "failed ocl"
echo "census done $(date -u +%H:%M:%SZ)"

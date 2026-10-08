#!/bin/sh
# r3-lanes screen: one shader timeline of apoa1pme mixed on the lanes build, under a timing hold.
export SHADER_HELD=1
T=/tmp/openmm-metal-bench/ultra-tools
D=/tmp/openmm-metal-bench/ultra-r3-lanes
mkdir -p $D/census
PRECISION=mixed $T/shader.sh $D/census mixed-apoa1pme apoa1pme $D 2
PRECISION=mixed $T/shader.sh $D/census base-mixed-apoa1pme apoa1pme /tmp/openmm-metal-bench/ultra-day-trial3 2

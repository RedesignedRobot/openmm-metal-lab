#!/bin/sh
# One timing hold: shader timeline of apoa1pme single on ultra-r1 and on this tree.
export SHADER_HELD=1
T=/tmp/openmm-metal-bench/ultra-tools
O=/tmp/openmm-metal-bench/ultra-r2-spread/census
$T/shader.sh $O r1-apoa1pme apoa1pme /tmp/openmm-metal-bench/ultra-r1 1 || echo "failed r1"
$T/shader.sh $O spread-apoa1pme apoa1pme /tmp/openmm-metal-bench/ultra-r2-spread 1 || echo "failed spread"
echo "census done $(date -u +%H:%M:%SZ)"

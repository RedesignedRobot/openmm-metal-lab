#!/bin/sh
# One timing hold: shader timelines of apoa1rf single on irl (tree d, 56.7k tiles), c16 (tree r, 91.2k half tiles)
# and c16h (tree h, whole+half tiles), for the per-tile and findBlocks cost split.
export SHADER_HELD=1
T=/tmp/openmm-metal-bench/ultra-tools
O=/tmp/openmm-metal-bench/ultra-r2-accum-nb/census
for x in irl:d c16:r c16h:h; do
    PRECISION=single $T/shader.sh $O ${x%:*}-apoa1rf apoa1rf /tmp/openmm-metal-bench/ultra-r2-accum-nb-${x#*:} 2 || echo "failed ${x%:*}"
done
echo "census done $(date -u +%H:%M:%SZ)"

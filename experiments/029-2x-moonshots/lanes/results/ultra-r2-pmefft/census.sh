#!/bin/sh
# One timing hold: shader timeline of pme and dhfr single on ultra-r2-spread and on this tree.
export SHADER_HELD=1
T=/tmp/openmm-metal-bench/ultra-tools
O=/tmp/openmm-metal-bench/ultra-r2-pmefft/census
for test in pme amber20-dhfr; do
    $T/shader.sh $O spread-$test $test /tmp/openmm-metal-bench/ultra-r2-spread 1 || echo "failed spread $test"
    $T/shader.sh $O fft-$test $test /tmp/openmm-metal-bench/ultra-r2-pmefft 1 || echo "failed fft $test"
done
echo "census done $(date -u +%H:%M:%SZ)"

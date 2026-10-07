#!/bin/sh
# Build the two replay trees one after the other, then their replay bridges.
set -u
T=/tmp/openmm-metal-bench/ultra-r2-accum-nb/t256
for t in r g; do
    rm -f /tmp/openmm-metal-bench/ultra-r2-accum-nb-$t/BUILT
    /tmp/openmm-metal-bench/ultra-tools/build.sh /tmp/openmm-metal-bench/ultra-r2-accum-nb-$t > /tmp/openmm-metal-bench/ultra-r2-accum-nb-$t/build5.out 2>&1
    echo "build $t exit $?"
    nice -n 10 sh $T/build-replay.sh /tmp/openmm-metal-bench/ultra-r2-accum-nb-$t $T/lib-$t.dylib > $T/bridge-$t.out 2>&1
    echo "bridge $t exit $?"
done
echo builds done

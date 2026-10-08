#!/bin/sh
# Rebuilds the mixed lane trees after the c1 and c3 fixes, in stack order, then marks the chain done.
M=/tmp/openmm-metal-bench/ultra-mixed
rm -f $M/rebuilt-0cad63bc2
for d in $M $M/t2 $M/t3 $M/t4 $M/t5; do
    echo "$(date -u +%H:%M:%SZ) build $d"
    /tmp/openmm-metal-bench/ultra-tools/build.sh $d || { echo "build of $d failed"; exit 1; }
done
touch $M/rebuilt-0cad63bc2
echo "$(date -u +%H:%M:%SZ) rebuild done"

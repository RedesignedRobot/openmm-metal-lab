#!/bin/sh
# Runs on the M3 Ultra under leased.sh: DISPATCH_MODE probe on one tree.
# Forces per mode, then 2 interleaved rounds of 15 s per mode and test.
# "none" (no barriers) gives wrong forces and GPU page faults, so it is not benchmarked.
set -u
D=/tmp/openmm-metal-bench/ultra-dispatch
out="$1"
mkdir -p "$out"
B=$D/src/examples/benchmarks
for mode in auto; do
    echo "mode $mode" >> "$out/forces.txt"
    DISPATCH_MODE=$mode DISPATCH_STATS=1 $D/py $D/fcheck.py $B gbsa,rf,pme,apoa1rf,apoa1pme,apoa1ljpme Metal:single >> "$out/forces.txt" 2>&1
done
BENCH_DIR=$B DISPATCH_STATS=1 sh $D/ab.sh "$out" 2 15 gbsa,rf,pme,amber20-dhfr \
    serial=$D/py:Metal:single barrier=$D/py:Metal:single:DISPATCH_MODE=barrier \
    auto=$D/py:Metal:single:DISPATCH_MODE=auto

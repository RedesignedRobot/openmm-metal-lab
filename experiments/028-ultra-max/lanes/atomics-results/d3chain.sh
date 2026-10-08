#!/bin/sh
# Design 3 step 1: once window 1 starts, build the serial base b919bfe7a in gb (build.sh waits for the window
# to end), keep its plugins as plugins-d3s for the screen, then dump its forces in 3 processes under a
# correctness ticket.
L=/tmp/openmm-metal-bench/ultra-atomics
T=/tmp/openmm-metal-bench/ultra-tools
until [ -f /tmp/openmm-window ]; do sleep 30; done
echo "$(date -u +%H:%M:%SZ) window seen, build.sh queued"
$T/build.sh $L/gb > $L/gb/build-d3s.out 2>&1 || { echo "BUILD FAILED"; tail -5 $L/gb/build-d3s.out; exit 1; }
grep -q '^commit b919bfe7a' $L/gb/BUILT || { echo "gb BUILT is not b919bfe7a"; exit 1; }
[ ! -e $L/plugins-d3s ] && cp -R $L/gb/prefix/lib/plugins $L/plugins-d3s && md5 -q $L/plugins-d3s/libOpenMMMetal.dylib
echo "$(date -u +%H:%M:%SZ) built, dumping"
$T/lease.sh --correctness ultra-atomics "d3 bitwise: serial base b919bfe7a, 3 dump processes" /bin/sh -c \
  "cd /tmp/openmm-metal-bench/ultra-base/benchmarks && for i in 1 2 3; do $L/gb/venv/bin/python $L/dumpd3.py $L/d3s-\$i.npz || exit 1; done && $L/gb/venv/bin/python $L/cmpd3.py $L/d3s-1.npz $L/d3s-2.npz $L/d3s-3.npz | tail -1"
echo "CHAIN EXIT $?"

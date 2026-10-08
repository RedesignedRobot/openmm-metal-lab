#!/bin/sh
# Design 3 bitwise check: waits for dispatch's d3floor (serial, b919bfe7a) and d3 (72af6f137) builds, checks
# each src against its BUILT hash, then in one correctness ticket dumps forces in 3 processes per build and
# compares all six with the first serial dump.
L=/tmp/openmm-metal-bench/ultra-atomics
D=/tmp/openmm-metal-bench/ultra-dispatch
T=/tmp/openmm-metal-bench/ultra-tools
ready() { grep -q "^commit $2" $D/$1/BUILT 2>/dev/null; }
until ready d3floor b919bfe7a && ready d3 72af6f137; do sleep 60; done
for t in d3floor d3; do
  [ "$($T/srchash.sh $D/$t)" = "$(sed -n 's/^src //p' $D/$t/BUILT)" ] || { echo "$t src changed after build.sh"; exit 1; }
done
echo "$(date -u +%H:%M:%SZ) both built, src matches BUILT"
$T/lease.sh --correctness ultra-atomics "d3 bitwise: d3floor vs d3, 3 dump processes each" /bin/sh -c \
  "cd /tmp/openmm-metal-bench/ultra-base/benchmarks && for t in d3floor d3; do for i in 1 2 3; do $D/\$t/venv/bin/python $L/dumpd3.py $L/bw-\$t-\$i.npz > $L/bw-\$t-\$i.log 2>&1 || { echo \"dump \$t \$i failed\"; exit 1; }; done; done && $D/d3floor/venv/bin/python $L/cmpd3.py $L/bw-d3floor-1.npz $L/bw-d3floor-2.npz $L/bw-d3floor-3.npz $L/bw-d3-1.npz $L/bw-d3-2.npz $L/bw-d3-3.npz > $L/bw-cmp.txt && tail -1 $L/bw-cmp.txt"
echo "CHECK EXIT $?"

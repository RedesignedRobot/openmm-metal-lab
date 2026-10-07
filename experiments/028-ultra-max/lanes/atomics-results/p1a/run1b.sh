#!/bin/sh
# Census 1b on the GPU: counters-mode profile of plugins-prof-b0 (71a602b43) against plugins-prof-bonded (d8ab45b2b),
# force evaluations only, as probe 1a. Refuses to run unless bbp.sh finished and both plugins match its md5s.
L=/tmp/openmm-metal-bench/ultra-atomics
O=$L/p1b/out
[ "$(ps -o nice= -p $$ | tr -d ' ')" = 0 ] || { echo "refusing: nice is not 0"; exit 1; }
grep -q "^bbp done" $L/bbp.out || { echo "bbp.sh did not finish"; exit 1; }
for v in prof-b0 prof-bonded; do
  grep -q "^$v $(md5 -q $L/plugins-$v/libOpenMMMetal.dylib) " $L/bbp.out || { echo "plugins-$v changed since bbp.sh"; exit 1; }
done
mkdir -p $O
run() {
  tag=$1-$2
  { echo "$tag load $(sysctl -n vm.loadavg) $(date -u +%H:%M:%SZ)"; ps -axo pcpu,command -r | head -5; } >> $O/loads.txt
  OPENMM_PLUGIN_DIR=$L/plugins-$2 GPUPROF=counters GPUPROF_OUT=$O/$tag.rec PROF_SECONDS=3 \
    $L/venv/bin/python $L/p1a/prof.py /tmp/openmm-metal-bench/ultra-base/benchmarks $1 single > $O/$tag.txt 2>&1 || echo "failed: $tag" >> $O/loads.txt
}
n=0
for test in apoa1rf apoa1pme amber20-cellulose pme gbsa rf; do
  if [ $((n % 2)) -eq 0 ]; then order="prof-b0 prof-bonded"; else order="prof-bonded prof-b0"; fi
  n=$((n+1))
  for v in $order; do run $test $v; done
done
echo done >> $O/loads.txt

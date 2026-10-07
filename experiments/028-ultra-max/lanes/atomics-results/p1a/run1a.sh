#!/bin/sh
# Probe 1a on the GPU: counters-mode profile of the atomicAdd variants, force evaluations only.
# gbsa and pme get only base and words, to split the words loss there into the fold and the nonbonded kernel.
# Runs under lease.sh; summarizing happens after the hold (sum1a.sh).
L=/tmp/openmm-metal-bench/ultra-atomics
O=$L/p1a/out
[ "$(ps -o nice= -p $$ | tr -d ' ')" = 0 ] || { echo "refusing: nice is not 0"; exit 1; }
mkdir -p $O
run() {
  tag=$1-$2
  { echo "$tag load $(sysctl -n vm.loadavg) $(date -u +%H:%M:%SZ)"; ps -axo pcpu,command -r | head -5; } >> $O/loads.txt
  OPENMM_PLUGIN_DIR=$L/plugins-$2 GPUPROF=counters GPUPROF_OUT=$O/$tag.rec PROF_SECONDS=3 \
    $L/venv/bin/python $L/p1a/prof.py /tmp/openmm-metal-bench/ultra-base/benchmarks $1 single > $O/$tag.txt 2>&1 || echo "failed: $tag" >> $O/loads.txt
}
n=0
for test in apoa1rf rf apoa1pme amber20-cellulose; do
  if [ $((n % 2)) -eq 0 ]; then order="prof prof-lo prof-plain prof-words"; else order="prof-words prof-plain prof-lo prof"; fi
  n=$((n+1))
  for v in $order; do run $test $v; done
done
for v in prof prof-words; do run gbsa $v; done
for v in prof-words prof; do run pme $v; done
echo done >> $O/loads.txt

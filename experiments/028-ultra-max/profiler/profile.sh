#!/bin/sh
# Runs on the M3 Ultra under the lease: prof.py on each test with one GpuProf.h mode, then summarize.py.
# usage: [PY=<python of a build with gpuprof.patch>] profile.sh <out dir> <mode> <precision> <tests, comma separated> [extra env]
# PY defaults to the profiler lane's venv. Modes: buffers, counters, split (see GpuProf.h).
D=/tmp/openmm-metal-bench/ultra-profiler
PY="${PY:-$D/venv/bin/python}"
out="$1"; mode="$2"; precision="$3"; tests="$4"; extra="${5:-}"
[ "$(ps -o nice= -p $$ | tr -d ' ')" = 0 ] || { echo "refusing: nice is $(ps -o nice= -p $$)"; exit 1; }
mkdir -p "$out"
for test in $(echo "$tests" | tr , ' '); do
    tag="$test-$precision-$mode"
    echo "$tag $extra load $(sysctl -n vm.loadavg) $(date -u +%H:%M:%SZ)" >> "$out/loads.txt"
    env $extra GPUPROF=$mode GPUPROF_OUT="$out/$tag.rec" "$PY" "$D/tools/prof.py" \
        "$D/src/examples/benchmarks" "$test" "$precision" > "$out/$tag.txt" 2>&1 || echo "failed: $tag" >> "$out/loads.txt"
    "$PY" "$D/tools/summarize.py" "$out/$tag.txt" "$out/$tag.rec" 8 > "$out/$tag.sum" 2>&1
    gzip -f "$out/$tag.rec"
done
echo "done $out"

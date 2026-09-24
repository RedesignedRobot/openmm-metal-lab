#!/bin/sh
# Runs on the M3 Ultra under the lease: prof.py inside an xctrace Metal System Trace, one trace per test, then one
# gpusweep.sh config as a smoke test of gpucapture and gpudebug.
# usage: xtrace.sh <out dir> <precision> <tests, comma separated>
# Window B records GpuProf.h split mode: one labeled encoder per kernel, so the trace names each kernel's interval, and
# the buffer records can be checked against GPUStartTime and GPUEndTime. Windows A and C against the unrecorded p1 walls
# price the trace itself. Export after the lease.
D=/tmp/openmm-metal-bench/ultra-profiler
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
out="$1"; precision="$2"; tests="$3"
[ "$(ps -o nice= -p $$ | tr -d ' ')" = 0 ] || { echo "refusing: nice is $(ps -o nice= -p $$)"; exit 1; }
mkdir -p "$out"
for test in $(echo "$tests" | tr , ' '); do
    tag="$test-$precision"
    echo "$tag load $(sysctl -n vm.loadavg) $(date -u +%H:%M:%SZ)" >> "$out/loads.txt"
    xcrun xctrace record --template 'Metal System Trace' --time-limit 120s --no-prompt --output "$out/$tag.trace" \
        --env PROF_SECONDS=2 --env GPUPROF=split --env GPUPROF_OUT="$out/$tag-split.rec" \
        --env PYTHONPATH="$D/venv/lib/python3.13/site-packages" --target-stdout "$out/$tag.txt" \
        --launch -- "$D/venv/bin/python" "$D/tools/prof.py" "$D/src/examples/benchmarks" "$test" "$precision" \
        > "$out/$tag.xctrace.log" 2>&1 || echo "failed: $tag, exit $?" >> "$out/loads.txt"
done
"$D/tools/gpusweep.sh" "$out/gpu" apoa1pme:12
echo "done $out"

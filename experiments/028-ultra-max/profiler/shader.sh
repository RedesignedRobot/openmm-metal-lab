#!/bin/sh
# Runs on the M3 Ultra under the lease: prof.py in a Metal System Trace with the shader timeline on, launch mode.
# usage: shader.sh <out dir> <check test> <test> <label=build dir>...
# The template is a copy of Xcode-beta 27.2's Metal System Trace with its shaderprofiler option set True
# (tmpl/mst-shader.tracetemplate; no xctrace flag turns the shader timeline on). The first trace is a short run of
# <check test> on the first build: if its metal-shader-profiler-intervals table is empty, the script stops there and the
# lease goes with it. Otherwise it traces <test> single on every build. No GPUPROF, so every build runs its own encoders.
# PYTHONPATH carries each build's venv and pydeps in case xctrace launches the venv's python outside its venv; the
# "openmm ... plugins ..." line in <tag>.txt names the package and plugin each trace loaded. Export after the lease.
set -u
D=/tmp/openmm-metal-bench/ultra-profiler
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
TEMPLATE=$D/tmpl/mst-shader.tracetemplate
BENCH=/tmp/openmm-metal-bench/ultra-base/benchmarks
CHECK_SECONDS=0.5
TRACE_SECONDS=1
out="$1"; check="$2"; test="$3"; shift 3
[ "$(ps -o nice= -p $$ | tr -d ' ')" = 0 ] || { echo "refusing: nice is $(ps -o nice= -p $$)"; exit 1; }
mkdir -p "$out"

trace() {  # tag, build dir, test, seconds
    echo "$1 load $(sysctl -n vm.loadavg) $(date -u +%H:%M:%SZ)" >> "$out/loads.txt"
    xcrun xctrace record --template "$TEMPLATE" --time-limit 120s --no-prompt --output "$out/$1.trace" \
        --env PROF_SECONDS="$4" --env PYTHONPATH="$2/venv/lib/python3.13/site-packages:$2/pydeps" \
        --target-stdout "$out/$1.txt" \
        --launch -- "$2/venv/bin/python" "$D/tools/prof.py" "$BENCH" "$3" single > "$out/$1.xctrace.log" 2>&1 \
        || echo "failed: $1, exit $?" >> "$out/loads.txt"
}

first="${1#*=}"
trace "check-$check" "$first" "$check" "$CHECK_SECONDS"
xcrun xctrace export --input "$out/check-$check.trace" \
    --xpath '/trace-toc/run[@number="1"]/data/table[@schema="metal-shader-profiler-intervals"]' > "$out/check-intervals.xml" 2>&1
status=$?
rows=$(grep -o "<row" "$out/check-intervals.xml" | wc -l | tr -d ' ')
echo "check $check: metal-shader-profiler-intervals has $rows rows, export exit $status $(date -u +%H:%M:%SZ)"
[ "$rows" -gt 0 ] || { echo "SHADER TIMELINE EMPTY"; exit 3; }
for arm in "$@"; do
    trace "$test-${arm%%=*}" "${arm#*=}" "$test" "$TRACE_SECONDS"
    echo "traced $test ${arm%%=*} $(date -u +%H:%M:%SZ)"
done
echo "done $out"

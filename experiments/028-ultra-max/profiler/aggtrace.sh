#!/bin/sh
# Runs on the M3 Ultra under the lease: workloads' rf concurrency question (lead-approved 02:50Z). One Metal System
# Trace per agg.py case, recorded with --all-processes because agg.py's children are separate processes.
# usage: aggtrace.sh <out dir>
# Cases, rf single, 10 s windows: Metal and OpenCL at N=1, then at N=4, all on ultra-base; then, only if the hold is
# under OPTIONAL_BY seconds old, the profiling tree with HD_NB_BLOCKS=6 HD_NB_TG=256 at N=1 and N=4. For each case,
# xctrace starts recording (START_WAIT s to say so, one retry), agg.py runs the case in the foreground, then xctrace
# is interrupted and the script waits for it to save (SAVE_WAIT s, then KILL) and exports metal-gpu-intervals. All
# of that stays inside the hold (RULES, GPU lease and timing); aggkicks.py reads the exports after release.
# agg.py refuses a case name that already has files in its dir, so its cases live in <out dir>/agg, apart from the traces.
set -u
D=/tmp/openmm-metal-bench/ultra-profiler
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
XCTRACE=$(xcrun --find xctrace)
AGG=/tmp/openmm-metal-bench/ultra-workloads/agg.py
BASE_PY=/tmp/openmm-metal-bench/ultra-base/venv/bin/python
NB_PY=$D/venv/bin/python
START_WAIT=15
SAVE_WAIT=180
STOP_WAIT=30
TIME_LIMIT=120
OPTIONAL_BY=300
out="$1"
[ "$(ps -o nice= -p $$ | tr -d ' ')" = 0 ] || { echo "refusing: nice is $(ps -o nice= -p $$)"; exit 1; }
mkdir -p "$out/agg"
cp -n /tmp/openmm-metal-bench/ultra-workloads/agg1/rf-system.xml /tmp/openmm-metal-bench/ultra-workloads/agg1/rf-positions.pdb "$out/agg/"
began=$(date +%s)

ended() {  # waits up to $2 s for pid $1 to exit, then kills it
    waited=0
    while kill -0 "$1" 2>/dev/null && [ $waited -lt $2 ]; do
        sleep 1
        waited=$((waited + 1))
    done
    ! kill -0 "$1" 2>/dev/null || kill -KILL "$1"
}

start() {  # <name>: starts xctrace detached, echoes its pid
    /bin/sh -c "nohup '$XCTRACE' record --template 'Metal System Trace' --all-processes --time-limit ${TIME_LIMIT}s \
        --no-prompt --output '$out/$1.trace' > '$out/$1.xctrace.log' 2>&1 < /dev/null & echo \$!"
}

recording() {  # <name> <xctrace pid>: waits up to START_WAIT s for the recording to start
    waited=0
    while [ $waited -lt $START_WAIT ]; do
        grep -q "Starting recording" "$out/$1.xctrace.log" 2>/dev/null && return 0
        kill -0 "$2" 2>/dev/null || return 1
        sleep 1
        waited=$((waited + 1))
    done
    return 1
}

trace_case() {  # <name> <n> <platform> <python> [<env assignments>...]
    name=$1; n=$2; platform=$3; py=$4; shift 4
    echo "$name load $(sysctl -n vm.loadavg) $(date -u +%H:%M:%SZ)" >> "$out/loads.txt"
    xpid=$(start "$name")
    if ! recording "$name" "$xpid"; then
        echo "$name: xctrace $xpid not recording after ${START_WAIT}s, retrying once"
        kill -INT "$xpid" 2>/dev/null
        ended "$xpid" $STOP_WAIT
        rm -rf "$out/$name.trace"
        xpid=$(start "$name")
        recording "$name" "$xpid" || { kill -INT "$xpid" 2>/dev/null; ended "$xpid" $STOP_WAIT; echo "failed: $name, xctrace not recording"; return 1; }
    fi
    env "$@" "$py" "$AGG" case "$out/agg" 10 "$name" "$n" "$platform" single rf > "$out/$name.agg.out" 2>&1
    status=$?
    kill -INT "$xpid" 2>/dev/null
    ended "$xpid" $SAVE_WAIT
    "$XCTRACE" export --input "$out/$name.trace" \
        --xpath '/trace-toc/run[@number="1"]/data/table[@schema="metal-gpu-intervals"]' \
        > "$out/$name-gpu-intervals.xml" 2> "$out/$name-gpu-intervals.err" || echo "$name: export failed"
    echo "$name $(date -u +%H:%M:%SZ): agg exit $status, $(tail -1 "$out/$name.agg.out")"
    [ $status = 0 ]
}

trace_case metal1 1 Metal "$BASE_PY" || exit 1
trace_case opencl1 1 OpenCL "$BASE_PY" || exit 1
trace_case metal4 4 Metal "$BASE_PY" || exit 1
trace_case opencl4 4 OpenCL "$BASE_PY" || exit 1
age=$(( $(date +%s) - began ))
if [ $age -ge $OPTIONAL_BY ]; then
    echo "skipped the nb6x256 arm: the hold is ${age}s old"
    exit 0
fi
trace_case nb1 1 Metal "$NB_PY" HD_NB_BLOCKS=6 HD_NB_TG=256 || exit 1
trace_case nb4 4 Metal "$NB_PY" HD_NB_BLOCKS=6 HD_NB_TG=256

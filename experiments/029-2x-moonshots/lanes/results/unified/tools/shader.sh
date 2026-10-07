#!/bin/sh
# Runs on the M3 Ultra under the lease: one prof.py run in a Metal System Trace with the shader timeline on, launch mode.
# usage: shader.sh <out dir> <tag> <test> <build dir> [<seconds>] [<check tag>]
# The template is a copy of Xcode-beta 27.2's Metal System Trace with its shaderprofiler option set True
# (tmpl/mst-shader.tracetemplate, from shadertemplate.py; no xctrace flag turns the shader timeline on). No GPUPROF, so
# the build runs its own encoders. xctrace's save and the export of metal-shader-profiler-intervals both run inside the
# hold, as the tail of the capture (RULES, GPU lease and timing): a save after release ran at about 5 cores through
# another lane's timing hold and voided its round. Only the row count into <tag>.rows ("export failed" if the export
# fails) runs after that, and it is one grep. With <check tag>, the script exits at once, without tracing, when
# <check tag>.rows reads 0: the shader timeline doesn't record here.
# A save that hasn't finished SAVE_WAIT seconds after the target exits is stopped by xctrace's pid, so nothing of this
# ticket outlives the hold. Each interrupted xctrace gets STOP_WAIT seconds to exit before KILL, and then the python it
# launched, whose pid prof.py writes to <tag>.pypid (PROF_PIDFILE), gets TERM and PY_STOP_WAIT seconds before KILL.
# If xctrace hasn't started recording within START_WAIT seconds, it is stopped by its pid and started once more, and a
# second failure exits, which releases the lease.
# PYTHONPATH carries the build's venv and pydeps in case xctrace launches the venv's python outside its venv; the
# "openmm ... plugins ..." line in <tag>.txt names the package and plugin the trace loaded.
set -u
D=/tmp/openmm-metal-bench/ultra-m29-unified
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
TEMPLATE=${TEMPLATE:-$D/tmpl/mst-shader.tracetemplate}  # limiter.sh passes a counter-profile template
PRECISION=${PRECISION:-single}
PLATFORM=${PLATFORM:-Metal}  # prof.py's platform; OpenCL runs on Metal here, so its kernels show in the shader timeline too
BENCH=/tmp/openmm-metal-bench/ultra-base/benchmarks
START_WAIT=15
SAVE_WAIT=120
STOP_WAIT=30
PY_STOP_WAIT=10
TIME_LIMIT=120
XCTRACE=$(xcrun --find xctrace)
out="$1"; tag="$2"; test="$3"; dir="$4"; seconds="${5:-1}"; check="${6:-}"
[ "$(ps -o nice= -p $$ | tr -d ' ')" = 0 ] || { echo "refusing: nice is $(ps -o nice= -p $$)"; exit 1; }
mkdir -p "$out"
if [ -n "$check" ] && [ "$(cat "$out/$check.rows" 2>/dev/null)" = 0 ]; then
    echo "skipped $tag: $check.rows is 0"
    exit 0
fi

start() {  # starts xctrace detached, echoes its pid
    rm -rf "$out/$tag.trace" "$out/$tag.pypid"
    /bin/sh -c "nohup '$XCTRACE' record --template '$TEMPLATE' --time-limit ${TIME_LIMIT}s --no-prompt \
        --output '$out/$tag.trace' --env PROF_SECONDS=$seconds --env PROF_PIDFILE='$out/$tag.pypid' \
        --env PYTHONPATH='$dir/venv/lib/python3.13/site-packages:$dir/pydeps' --target-stdout '$out/$tag.txt' \
        --launch -- '$dir/venv/bin/python' '$D/tools/prof.py' '$BENCH' '$test' '$PRECISION' '$PLATFORM' \
        > '$out/$tag.xctrace.log' 2>&1 < /dev/null & echo \$!"
}

recording() {  # waits up to START_WAIT s for xctrace pid $1 to report the launch
    waited=0
    while [ $waited -lt $START_WAIT ]; do
        grep -q "Starting recording" "$out/$tag.xctrace.log" 2>/dev/null && return 0
        kill -0 "$1" 2>/dev/null || return 1
        sleep 1
        waited=$((waited + 1))
    done
    return 1
}

ended() {  # waits up to $2 s for pid $1 to exit, then kills it
    waited=0
    while kill -0 "$1" 2>/dev/null && [ $waited -lt $2 ]; do
        sleep 1
        waited=$((waited + 1))
    done
    ! kill -0 "$1" 2>/dev/null || kill -KILL "$1"
}

stopped() {  # after interrupting xctrace pid $1: ends it, then the python it launched, so neither outlives the hold
    ended "$1" $STOP_WAIT
    pypid=$(cat "$out/$tag.pypid" 2>/dev/null)
    [ -n "$pypid" ] && kill -0 "$pypid" 2>/dev/null || return 0
    kill -TERM "$pypid"
    ended "$pypid" $PY_STOP_WAIT
}

echo "$tag load $(sysctl -n vm.loadavg) $(date -u +%H:%M:%SZ)" >> "$out/loads.txt"
xpid=$(start)
if ! recording "$xpid"; then
    echo "$tag: xctrace $xpid not recording after ${START_WAIT}s, stopping it and retrying once"
    kill -INT "$xpid" 2>/dev/null
    stopped "$xpid"
    xpid=$(start)
    recording "$xpid" || { kill -INT "$xpid" 2>/dev/null; stopped "$xpid"; echo "failed: $tag, xctrace $xpid not recording, releasing"; exit 1; }
fi
echo "$tag: xctrace pid $xpid recording $(date -u +%H:%M:%SZ)"
until grep -q -E "Target app exited|Recording completed|rror" "$out/$tag.xctrace.log" 2>/dev/null || ! kill -0 "$xpid" 2>/dev/null; do
    sleep 0.2
done
echo "captured $tag $(date -u +%H:%M:%SZ): $(tail -1 "$out/$tag.xctrace.log")"
waited=0
while kill -0 "$xpid" 2>/dev/null && [ $waited -lt $SAVE_WAIT ]; do
    sleep 1
    waited=$((waited + 1))
done
if kill -0 "$xpid" 2>/dev/null; then
    kill -INT "$xpid"
    stopped "$xpid"
    echo "failed: $tag, xctrace $xpid still saving after ${SAVE_WAIT}s, stopped it"
    exit 1
fi
echo "saved $tag $(date -u +%H:%M:%SZ): $(tail -1 "$out/$tag.xctrace.log")"
if "$XCTRACE" export --input "$out/$tag.trace" \
    --xpath '/trace-toc/run[@number="1"]/data/table[@schema="metal-shader-profiler-intervals"]' \
    > "$out/$tag-intervals.xml" 2> "$out/$tag-intervals.err"; then
    grep -o "<row" "$out/$tag-intervals.xml" | wc -l | tr -d " " > "$out/$tag.rows"
else
    echo "export failed" > "$out/$tag.rows"
fi
echo "exported $tag $(date -u +%H:%M:%SZ), rows $(cat "$out/$tag.rows"), releasing"

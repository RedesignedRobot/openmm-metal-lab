#!/bin/sh
# One sampled shader timeline of one work unit (r3-fah): ultra-tools/shader.sh with profwu.py as the target.
# usage: tracewu.sh <out dir> <tag> <wu dir> <build dir> <seconds> [variant ...]
# PRECISION (single, mixed) and PLATFORM (Metal, OpenCL) come from the environment. Run it only inside a gpuq timing
# job (tracebatch.sh); it takes no ticket of its own. Same safety as shader.sh: xctrace is stopped by its recorded
# pid, the python it launched by the pid profwu.py writes, and every exit runs xctemp.sh for the ktrace xctrace
# leaves in the user temp dir.
set -eu
[ $# -ge 5 ] || { echo "usage: tracewu.sh <out> <tag> <wu> <build> <seconds> [variant ...]" >&2; exit 2; }
D=/tmp/openmm-metal-bench/ultra-tools
HERE=$(cd "$(dirname "$0")" && pwd)
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
TEMPLATE=$D/tmpl/mst-shader.tracetemplate
PLATFORM=${PLATFORM:-Metal}
PRECISION=${PRECISION:-mixed}
START_WAIT=15
SAVE_WAIT=150
STOP_WAIT=30
PY_STOP_WAIT=10
TIME_LIMIT=120
XCTRACE=$(xcrun --find xctrace)
out="$1"; tag="$2"; wu="$3"; dir="$4"; seconds="$5"; shift 5
variants="$*"
[ "$(ps -o nice= -p $$ | tr -d ' ')" = 0 ] || { echo "refusing: nice is $(ps -o nice= -p $$)"; exit 1; }
[ ! -e "$out/$tag.trace" ] || { echo "refusing: $out/$tag.trace exists"; exit 1; }
mkdir -p "$out"

start() {  # starts xctrace detached, echoes its pid
    /bin/sh -c "nohup '$XCTRACE' record --template '$TEMPLATE' --time-limit ${TIME_LIMIT}s --no-prompt \
        --output '$out/$tag.trace' --env PROF_SECONDS=$seconds --env PROF_PIDFILE='$out/$tag.pypid' \
        --env PYTHONPATH='$dir/venv/lib/python3.13/site-packages:$dir/pydeps' --target-stdout '$out/$tag.txt' \
        --launch -- '$dir/venv/bin/python' '$HERE/profwu.py' '$wu' '$PRECISION' '$PLATFORM' $variants \
        > '$out/$tag.xctrace.log' 2>&1 < /dev/null & echo \$!"
}

recording() {
    waited=0
    while [ $waited -lt $START_WAIT ]; do
        grep -q "Starting recording" "$out/$tag.xctrace.log" 2>/dev/null && return 0
        kill -0 "$1" 2>/dev/null || return 1
        sleep 1
        waited=$((waited + 1))
    done
    return 1
}

ended() {
    waited=0
    while kill -0 "$1" 2>/dev/null && [ $waited -lt $2 ]; do
        sleep 1
        waited=$((waited + 1))
    done
    ! kill -0 "$1" 2>/dev/null || kill -KILL "$1"
}

stopped() {
    ended "$1" $STOP_WAIT
    pypid=$(cat "$out/$tag.pypid" 2>/dev/null)
    [ -n "$pypid" ] && kill -0 "$pypid" 2>/dev/null || return 0
    kill -TERM "$pypid"
    ended "$pypid" $PY_STOP_WAIT
}

interrupted() {
    [ -z "$xpid" ] || { kill -INT "$xpid" 2>/dev/null; stopped "$xpid"; }
    exit "$1"
}

xpid=""
trap "$D/xctemp.sh" EXIT
trap 'interrupted 129' HUP
trap 'interrupted 130' INT
trap 'interrupted 143' TERM
echo "$tag load $(sysctl -n vm.loadavg) $(date -u +%H:%M:%SZ)" >> "$out/loads.txt"
xpid=$(start)
recording "$xpid" || { kill -INT "$xpid" 2>/dev/null; stopped "$xpid"; echo "failed: $tag, xctrace $xpid not recording"; exit 1; }
echo "$tag: xctrace pid $xpid recording $(date -u +%H:%M:%SZ)"
until grep -q -E "Target app exited|Recording completed|rror" "$out/$tag.xctrace.log" 2>/dev/null || ! kill -0 "$xpid" 2>/dev/null; do
    sleep 0.2
done
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
if "$XCTRACE" export --input "$out/$tag.trace" \
    --xpath '/trace-toc/run[@number="1"]/data/table[@schema="metal-shader-profiler-intervals"]' \
    > "$out/$tag-intervals.xml" 2> "$out/$tag-intervals.err"; then
    grep -o "<row" "$out/$tag-intervals.xml" | wc -l | tr -d " " > "$out/$tag.rows"
else
    echo "export failed" > "$out/$tag.rows"
    exit 1
fi
echo "exported $tag $(date -u +%H:%M:%SZ), rows $(cat "$out/$tag.rows"): $(tail -1 "$out/$tag.txt")"
[ "$(cat "$out/$tag.rows")" -gt 0 ] || { echo "no sampled shader rows recorded" >&2; exit 1; }

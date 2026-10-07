#!/bin/sh
# M0(2), one timing hold: Apple9 GPU counters for apoa1rf single on each <label>=<tree>[,VAR=value...].
# prof.py runs under MTL_CAPTURE_ENABLED=1 (PROF_SECONDS=30, three windows); once window A is printed,
# gpucapture takes CAPTURE_COUNT command buffers (Device boundary) into <label>.gputrace, prof.py is stopped,
# and gdwalk.py replays the trace with `gpudebug profile run --embed` and dumps /performance to <label>/.
# Every GPU step happens inside this hold; nothing is left running after it. Every gpucapture and gpudebug call runs
# under an alarm (gpucapture waited 4 min on a macOS password prompt in the 15:25Z hold). Worst case per spec is
# about 11 minutes (40 s to window A, 180 s capture, 420 s gdwalk), so counters-launch.sh gives each spec its own
# hold, after a preflight that proves gpucapture and gpudebug answer.
# usage: lease.sh r2-infra "M0 counters" counters.sh [r1=/tmp/.../ultra-r1 sub=/tmp/.../tree,P_X=0 ...]
# With no arguments the specs come from counters.specs (one per line), read when the hold starts.
set -u
M=/tmp/openmm-metal-bench/ultra-infra/m0
BENCH=/tmp/openmm-metal-bench/ultra-base/benchmarks
CAPTURE_COUNT=${CAPTURE_COUNT:-12}
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
utc() { date -u +%H:%M:%SZ; }
alarm() { perl -e '$t = shift; alarm $t; exec @ARGV' "$@"; }
[ $# -gt 0 ] || set -- $(grep -v '^#' "$M/counters.specs")
for spec in "$@"; do
    label=${spec%%=*}
    rest=${spec#*=}
    tree=${rest%%,*}
    envs=""
    [ "$rest" = "$tree" ] || envs=$(echo "${rest#*,}" | tr ',' ' ')
    out=$M/$label
    rm -rf "$out" "$M/$label.gputrace"
    mkdir -p "$out"
    echo "$label: $tree env [$envs] $(utc)"
    env $envs MTL_CAPTURE_ENABLED=1 PROF_SECONDS=30 PROF_PIDFILE="$out/pypid" \
        "$tree/venv/bin/python" /tmp/openmm-metal-bench/ultra-tools/prof.py "$BENCH" apoa1rf single Metal > "$out/prof.txt" 2>&1 &
    runner=$!
    waited=0
    until grep -q "^window A" "$out/prof.txt" 2>/dev/null || [ $waited -ge 120 ] || ! kill -0 $runner 2>/dev/null; do
        sleep 1
        waited=$((waited + 1))
    done
    pid=$(cat "$out/pypid" 2>/dev/null)
    if ! grep -q "^window A" "$out/prof.txt"; then
        echo "$label: no window A after $waited s, skipping"; kill -TERM $runner 2>/dev/null; wait $runner; continue
    fi
    alarm 15 gpucapture list > "$out/capturable.txt" 2>&1 || { echo "$label: gpucapture list rc $? (alarm 15 s), skipping"; kill -TERM $runner 2>/dev/null; wait $runner; continue; }
    alarm 15 gpucapture boundaries --pid "$pid" > "$out/boundaries.txt" 2>&1
    echo "$label: capturing pid $pid $(utc)"
    alarm 180 gpucapture start --pid "$pid" --count "$CAPTURE_COUNT" --output "$M/$label.gputrace" > "$out/capture.txt" 2>&1 &
    cap=$!
    waited=0
    while kill -0 $cap 2>/dev/null && [ $waited -lt 150 ]; do
        sleep 1
        waited=$((waited + 1))
    done
    kill -0 $cap 2>/dev/null && { echo "$label: gpucapture still running after 150 s, stopping"; alarm 30 gpucapture stop --pid "$pid" >> "$out/capture.txt" 2>&1; sleep 5; kill -TERM $cap 2>/dev/null; }
    wait $cap
    echo "$label: capture rc $? $(utc): $(tail -2 "$out/capture.txt" | tr '\n' ' ')"
    kill -TERM $runner 2>/dev/null
    wait $runner
    [ -e "$M/$label.gputrace" ] || { echo "$label: no trace written"; continue; }
    du -sh "$M/$label.gputrace"
    /tmp/openmm-metal-bench/env/bin/python3 "$M/gdwalk.py" "$M/$label.gputrace" "$out" 2>&1 | sed "s/^/$label: /"
    echo "$label: done $(utc)"
done
echo "counters done $(utc)"

#!/bin/sh
# Runs on the M3 Ultra under the lease: gpucapture plus gpudebug profile of prof.py at several grid caps (HD_TBPC).
# usage: gpusweep.sh <out dir> <test:tbpc,...>, for example apoa1pme:12,apoa1pme:24
# Per config: launch prof.py with MTL_CAPTURE_ENABLED=1, capture 8 command buffers (4 steps) once window A has printed,
# stop prof.py, replay the capture with profile run --gpu-state high --exec serial, and list the shader, dispatch and
# encoder costs and the counters. GPUPROF=split labels every pipeline and gives window B, the captured one, one labeled
# encoder per kernel. Starts no new config after 13 minutes, so the hold stays under 20.
# Retired 2026-09-24 23:23Z, broken: prof.py exits about 6 s after window A prints (windows B and C at PROF_SECONDS=3),
# before gpucapture attaches, so gpucapture waits on a dead pid until its 120 s timeout with the lease held and the GPU
# idle (xtrace hold, 23:21Z). It also runs under timeout(1) in its own process group, which lease.sh's group stop misses.
# Before reuse: make prof.py wait on a go file until gpucapture reports attached, check the pid before capturing, and
# fail in seconds.
D=/tmp/openmm-metal-bench/ultra-profiler
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
out="$1"; configs="$2"
[ "$(ps -o nice= -p $$ | tr -d ' ')" = 0 ] || { echo "refusing: nice is $(ps -o nice= -p $$)"; exit 1; }
mkdir -p "$out"
deadline=$(( $(date +%s) + 780 ))
for config in $(echo "$configs" | tr , ' '); do
    test="${config%%:*}"; tbpc="${config##*:}"; tag="$test-tbpc$tbpc"
    [ "$(date +%s)" -lt "$deadline" ] || { echo "skipped $tag: out of time" >> "$out/loads.txt"; continue; }
    echo "$tag load $(sysctl -n vm.loadavg) $(date -u +%H:%M:%SZ)" >> "$out/loads.txt"
    MTL_CAPTURE_ENABLED=1 HD_TBPC=$tbpc PROF_SECONDS=3 GPUPROF=split GPUPROF_OUT="$out/$tag-split.rec" "$D/venv/bin/python" "$D/tools/prof.py" \
        "$D/src/examples/benchmarks" "$test" single > "$out/$tag.txt" 2>&1 &
    pid=$!
    waited=0
    until grep -q "^window A" "$out/$tag.txt" || ! kill -0 $pid 2>/dev/null || [ $waited -ge 120 ]; do
        sleep 1; waited=$((waited+1))
    done
    if ! grep -q "^window A" "$out/$tag.txt"; then
        echo "failed: $tag never reached window A" >> "$out/loads.txt"
        kill $pid 2>/dev/null; wait $pid 2>/dev/null
        continue
    fi
    timeout 120 gpucapture start --pid $pid --count 8 --output "$out/$tag.gputrace" > "$out/$tag.capture.log" 2>&1 \
        || echo "failed: $tag capture, exit $?" >> "$out/loads.txt"
    kill $pid 2>/dev/null; wait $pid 2>/dev/null
    [ -e "$out/$tag.gputrace" ] || { echo "failed: $tag no trace" >> "$out/loads.txt"; continue; }
    timeout 300 gpudebug -q --json --oneshot -t "$out/$tag.gputrace" \
        -c "profile run --gpu-state high --exec serial --embed" \
        -c "go /performance/shaders" -c "list --all" \
        -c "go /performance/commands" -c "list --all" \
        -c "go /performance/encoders" -c "list --all" \
        -c "go /performance/timeline/counters" -c "list --all" > "$out/$tag.profile.json" 2>&1 \
        || echo "failed: $tag profile, exit $?" >> "$out/loads.txt"
    echo "$tag finished $(date -u +%H:%M:%SZ)" >> "$out/loads.txt"
done
echo "done $out"

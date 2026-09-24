#!/bin/sh
# Runs on the M3 Ultra under the lease: per-kernel census of several arms in counters mode, with repeats.
# usage: census.sh <out dir> <precision> <tests, comma separated> <repeats> <arm>...
# An arm is name or name:VAR=value,VAR=value. Every arm runs prof.py from this lane's venv with its variables set,
# for example base, tbpc24:HD_TBPC=24, or cand:OPENMM_PLUGIN_DIR=<prefix of a build with gpuprof.patch>/lib/plugins.
# Arms run interleaved within each test and repeat, in reversed order on every other repeat. Summaries are left for
# census.py after the lease. Starts no new run after 14 minutes, so the hold stays under the 20-minute cap.
D=/tmp/openmm-metal-bench/ultra-profiler
out="$1"; precision="$2"; tests="$3"; repeats="$4"
shift 4
[ "$(ps -o nice= -p $$ | tr -d ' ')" = 0 ] || { echo "refusing: nice is $(ps -o nice= -p $$)"; exit 1; }
mkdir -p "$out"
arms="$*"
reversed=$(for arm in $arms; do echo "$arm"; done | tail -r | tr '\n' ' ')
deadline=$(( $(date +%s) + 840 ))
repeat=1
while [ $repeat -le "$repeats" ]; do
    order="$arms"
    [ $((repeat % 2)) = 0 ] && order="$reversed"
    for test in $(echo "$tests" | tr , ' '); do
        for arm in $order; do
            name="${arm%%:*}"; vars=""
            [ "$name" = "$arm" ] || vars="$(echo "${arm#*:}" | tr , ' ')"
            tag="$name-$test-$precision-r$repeat"
            [ "$(date +%s)" -lt "$deadline" ] || { echo "skipped $tag: out of time" >> "$out/loads.txt"; continue; }
            echo "$tag $vars load $(sysctl -n vm.loadavg) $(date -u +%H:%M:%SZ)" >> "$out/loads.txt"
            env $vars PROF_SECONDS=2 GPUPROF=counters GPUPROF_OUT="$out/$tag.rec" "$D/venv/bin/python" "$D/tools/prof.py" \
                "$D/src/examples/benchmarks" "$test" "$precision" > "$out/$tag.txt" 2>&1 || echo "failed: $tag" >> "$out/loads.txt"
        done
    done
    repeat=$((repeat+1))
done
echo "done $out"

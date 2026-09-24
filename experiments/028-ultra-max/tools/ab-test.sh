#!/bin/sh
# Called by ab.sh under the lease: one test of one round, each configuration in the order given.
# Before each run it logs the load, the Hyperscale VM's CPU and the top 5 CPU processes, and marks the
# run BUILD RUNNING if a build runs then (lease.sh never waits for builds) or starts during the run.
# A CPU-platform run also logs the platform's thread count, and every 5 s during the run samples the
# benchmark process's %CPU, the busiest other process and the Hyperscale VM; one line in loads.txt
# sums them up, marked CPU BUSY if another process went over 100%, since shared load slows the CPU
# platform directly.
# AB_OUT, AB_ROUND, AB_TEST and AB_SECONDS come from ab.sh.
# usage: ab-test.sh <configuration>...
set -eu
BUILDS='clang|clang\+\+|ninja|cc1plus'
CPU_SAMPLE_SECONDS=5
CPU_BUSY_PERCENT=100
for config in "$@"; do
    label="${config%%=*}"
    IFS=: read -r python platform precision settings <<SPEC
${config#*=}
SPEC
    env_settings="$(echo "${settings:-}" | tr , ' ')"
    result="$AB_OUT/$label-$AB_TEST-round$AB_ROUND.json"
    build_note=""
    pgrep -x "$BUILDS" > /dev/null && build_note=" BUILD RUNNING"
    vm="$(ps -Ao pcpu=,comm= | awk '/Virtualization\.VirtualMachine/ { cpu += $1 } END { printf "%.0f%%", cpu }')"
    top="$(ps -Aro pcpu=,comm= | head -5 | awk '{ cpu = $1; $1 = ""; n = split($0, path, "/"); printf "%s %s%%, ", path[n], cpu }')"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) round $AB_ROUND $AB_TEST $label load $(sysctl -n vm.loadavg)$build_note vm $vm top ${top%, }" >> "$AB_OUT/loads.txt"
    # One pgrep a second during the run catches a build that starts after the check above.
    rm -f "$AB_OUT/.build-seen"
    ( while :; do pgrep -x "$BUILDS" > /dev/null && { touch "$AB_OUT/.build-seen"; exit 0; }; sleep 1; done ) &
    watcher=$!
    sampler=""
    if [ "$platform" = CPU ]; then
        threads="$(cd / && env $env_settings "$python" -c "import openmm; print(openmm.Platform.getPlatformByName('CPU').getPropertyDefaultValue('Threads'))" 2>/dev/null || echo unknown)"
        : > "$AB_OUT/.cpu-samples"
        # Each sample: benchmark %CPU, the busiest other process's %CPU and name, the VM's %CPU.
        ( while sleep $CPU_SAMPLE_SECONDS; do
              pid="$(pgrep -f -- "--outfile $result" | head -1)"
              [ -n "$pid" ] || continue
              ps -Ao pid=,pcpu=,comm= | awk -v bench="$pid" '
                  $1 == bench { own = $2; next }
                  { n = split($3, path, "/"); if ($2 > top) { top = $2; name = path[n] } }
                  /Virtualization\.VirtualMachine/ { vm += $2 }
                  END { printf "%.0f %.0f %s %.0f\n", own, top, name, vm }'
          done >> "$AB_OUT/.cpu-samples" ) &
        sampler=$!
    fi
    # perl's alarm survives exec, so a hung run dies after the cap.
    env $env_settings perl -e 'alarm shift; exec @ARGV' $((AB_SECONDS + 900)) "$python" benchmark.py \
        --platform "$platform" --precision "$precision" --test "$AB_TEST" --seconds "$AB_SECONDS" \
        --style table --outfile "$result" 2>&1 | grep -v Warning || true
    kill $watcher 2>/dev/null || true
    wait $watcher 2>/dev/null || true
    if [ -n "$sampler" ]; then
        kill $sampler 2>/dev/null || true
        wait $sampler 2>/dev/null || true
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) round $AB_ROUND $AB_TEST $label cpu threads $threads, $(awk -v busy=$CPU_BUSY_PERCENT '
            { n++; if (n == 1 || $1 < low) low = $1; if ($1 > high) high = $1; if ($2 > top) { top = $2; name = $3 } if ($4 > vm) vm = $4 }
            END { printf "%d samples: benchmark %d%% to %d%%, busiest other %d%% (%s), VM up to %d%%%s", n, low, high, top, name, vm, (top > busy ? " CPU BUSY" : "") }' "$AB_OUT/.cpu-samples")" >> "$AB_OUT/loads.txt"
        rm -f "$AB_OUT/.cpu-samples"
    fi
    [ -z "$build_note" ] && [ -e "$AB_OUT/.build-seen" ] \
        && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) round $AB_ROUND $AB_TEST $label BUILD RUNNING during the run" >> "$AB_OUT/loads.txt"
    rm -f "$AB_OUT/.build-seen"
    [ -s "$result" ] || echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) NO RESULT round $AB_ROUND $AB_TEST $label" | tee -a "$AB_OUT/loads.txt"
done

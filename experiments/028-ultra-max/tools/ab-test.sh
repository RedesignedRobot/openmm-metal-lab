#!/bin/sh
# Called by ab.sh under the lease: one test of one round, each configuration in the order given.
# Before each run it logs the load, the Hyperscale VM's CPU and the top 5 CPU processes, and marks the
# run BUILD RUNNING if a build runs then (lease.sh never waits for builds) or starts during the run.
# AB_OUT, AB_ROUND, AB_TEST and AB_SECONDS come from ab.sh.
# usage: ab-test.sh <configuration>...
set -eu
BUILDS='clang|clang\+\+|ninja|cc1plus'
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
    # perl's alarm survives exec, so a hung run dies after the cap.
    env $env_settings perl -e 'alarm shift; exec @ARGV' $((AB_SECONDS + 900)) "$python" benchmark.py \
        --platform "$platform" --precision "$precision" --test "$AB_TEST" --seconds "$AB_SECONDS" \
        --style table --outfile "$result" 2>&1 | grep -v Warning || true
    kill $watcher 2>/dev/null || true
    wait $watcher 2>/dev/null || true
    [ -z "$build_note" ] && [ -e "$AB_OUT/.build-seen" ] \
        && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) round $AB_ROUND $AB_TEST $label BUILD RUNNING during the run" >> "$AB_OUT/loads.txt"
    rm -f "$AB_OUT/.build-seen"
    [ -s "$result" ] || echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) NO RESULT round $AB_ROUND $AB_TEST $label" | tee -a "$AB_OUT/loads.txt"
done

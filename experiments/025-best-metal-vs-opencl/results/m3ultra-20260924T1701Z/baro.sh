#!/bin/sh
# Runs on the Studio: TestMetalMonteCarloFlexibleBarostat <precision>, <runs> times on each build,
# interleaved, with the build order reversed every other run. hd is evwait's 6df2b8bcb build, p9074 is
# its parent 9074c38f1, ref is 052eaa85b (the tree the M2's hipdelta-ref held). Each run's output goes to baro/<build>-<precision>-<i>.txt; exit code, seconds and the
# load averages before the run go to baro/summary-<precision>.txt.
# usage: baro.sh <single|mixed> <runs>
set -eu
D=/tmp/openmm-metal-bench/m3ab
precision="$1"
runs="$2"
mkdir -p "$D/baro"
i=1
while [ "$i" -le "$runs" ]; do
    order="hd p9074 ref"
    [ $((i % 2)) -eq 0 ] && order="ref p9074 hd"
    for build in $order; do
        dir="$D/$build/build"
        [ "$build" = hd ] && dir=/tmp/openmm-metal-bench/evwait/src/build
        load="$(sysctl -n vm.loadavg)"
        start=$(date +%s)
        code=0
        (cd "$dir" && ./TestMetalMonteCarloFlexibleBarostat "$precision") > "$D/baro/$build-$precision-$i.txt" 2>&1 || code=$?
        echo "$(date -u +%H:%M:%SZ) $build $precision run $i exit $code $(( $(date +%s) - start ))s nice $(ps -o nice= -p $$ | tr -d " ") load $load" >> "$D/baro/summary-$precision.txt"
    done
    i=$((i+1))
done

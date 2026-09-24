#!/bin/sh
# Runs on the mini: benchmark.py rounds over several configurations, one fresh process per
# (round, test, configuration). Within a test the configurations run back to back, and their
# order reverses every other round. A configuration is label=python:platform:precision[:VAR=value,...].
# benchmark.py times with the host clock (datetime.now() around step() plus a getState() sync).
# Before every run the 1, 5 and 15 minute load averages go to loads.txt.
# BENCH_DIR picks the examples/benchmarks copy, default the final tree's.
# usage: ab.sh <outdir> <rounds> <seconds> <tests> <configuration>...
set -eu
out="$1"
rounds="$2"
seconds="$3"
tests="$(echo "$4" | tr , ' ')"
shift 4
mkdir -p "$out"
configs="$*"
reversed="$(echo $configs | tr ' ' '\n' | tail -r | tr '\n' ' ')"
cd "${BENCH_DIR:-$HOME/lab/fast/src/examples/benchmarks}"
r=1
while [ "$r" -le "$rounds" ]; do
    order="$configs"
    [ $((r % 2)) -eq 0 ] && order="$reversed"
    for test in $tests; do
        for config in $order; do
            label="${config%%=*}"
            IFS=: read -r python platform precision settings <<SPEC
${config#*=}
SPEC
            env_settings="$(echo "${settings:-}" | tr , ' ')"
            echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) round $r $test $label load $(sysctl -n vm.loadavg)" >> "$out/loads.txt"
            env $env_settings "$python" benchmark.py --platform "$platform" --precision "$precision" --test "$test" \
                --seconds "$seconds" --style table --outfile "$out/$label-$test-round$r.json" 2>&1 | grep -v Warning || true
            [ -s "$out/$label-$test-round$r.json" ] || echo "$(date -u +%H:%M:%SZ) NO RESULT round $r $test $label" | tee -a "$out/loads.txt"
        done
    done
    r=$((r+1))
done
echo "$out"

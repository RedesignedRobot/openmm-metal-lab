#!/bin/sh
# Runs on the Studio: one benchmark.py run per test and knob setting, knobs as env assignments.
# usage: screen.sh <seconds> <tests> <label=VAR=v,VAR=v|label=>...
D=/tmp/openmm-metal-bench/hipdelta
seconds="$1"; tests="$2"; shift 2
out="$D/screen-$(date -u +%Y%m%dT%H%MZ)"
mkdir -p "$out"
for test in $(echo "$tests" | tr , ' '); do
    for spec in "$@"; do
        label="${spec%%=*}"; vars="$(echo "${spec#*=}" | tr , ' ')"
        before=$(sysctl -n vm.loadavg)
        (cd "$D/hipdelta/examples/benchmarks" && env $vars "$D/venv-hipdelta/bin/python" benchmark.py --platform Metal \
            --precision single --test "$test" --seconds "$seconds" --outfile "$out/$label-$test.json" > /dev/null 2>&1)
        echo "$test $label $(python3 -c "import json,sys; print(round(json.load(open(sys.argv[1]))['benchmarks'][0]['ns_per_day'],1))" "$out/$label-$test.json" 2>/dev/null || echo fail) load $before" | tee -a "$out/summary.txt"
    done
done

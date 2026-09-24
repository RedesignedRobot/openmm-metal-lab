#!/bin/sh
# Runs on the Studio: interleaved benchmark.py rounds of several variants, reversing their order
# every other round. A variant is label=tree or label=tree:VAR=value,VAR=value, and each tree has
# its own venv. The 1, 5 and 15 minute load averages before every run go to loads.txt, and the
# hostname in each JSON becomes "M3 Ultra".
# usage: screen.sh <rounds> <seconds> <tests, comma separated> <variant>...
set -eu
D=/tmp/openmm-metal-bench/hipdelta
rounds="$1"; seconds="$2"; tests="$3"; shift 3
out="$D/screen-$(date -u +%Y%m%dT%H%MZ)"
mkdir -p "$out"
variants="$*"
reversed="$(echo $variants | tr ' ' '\n' | tail -r | tr '\n' ' ')"
r=1
while [ "$r" -le "$rounds" ]; do
    order="$variants"
    [ $((r % 2)) -eq 0 ] && order="$reversed"
    for test in $(echo "$tests" | tr , ' '); do
        for variant in $order; do
            label="${variant%%=*}"; spec="${variant#*=}"; tree="${spec%%:*}"; settings=""
            [ "$spec" != "$tree" ] && settings="$(echo "${spec#*:}" | tr , ' ')"
            echo "round $r $test $label load $(sysctl -n vm.loadavg)" >> "$out/loads.txt"
            json="$out/$label-$test-round$r.json"
            (cd "$D/$tree/examples/benchmarks" && env $settings "$D/venv-$tree/bin/python" benchmark.py --platform Metal \
                --precision single --test "$test" --seconds "$seconds" --outfile "$json" > /dev/null 2>&1) || true
            [ -f "$json" ] && sed -i '' 's/"hostname": "[^"]*"/"hostname": "M3 Ultra"/' "$json"
            grep -q ns_per_day "$json" 2>/dev/null || echo "no result: round $r $test $label" | tee -a "$out/loads.txt"
        done
    done
    r=$((r+1))
done
echo "$out"

#!/bin/sh
# Runs on the Studio under the lease: benchmark.py on the gbsa-gap builds, interleaved per test and
# alternating which goes first each round. Load averages before and after every run go to
# loads.txt, since the owner may be at the keyboard.
# usage: gbsa-bench.sh <rounds> <seconds> <tests, comma separated> [trees, default "hd proto ref"]
set -eu
D=/tmp/openmm-metal-bench/gbsa-gap
rounds="$1"
seconds="$2"
tests="$3"
trees="${4:-hd proto ref}"
out="$D/bench-$(date -u +%Y%m%dT%H%MZ)"
export PYTHONPATH=$D/pydeps
mkdir -p "$out"
r=1
while [ "$r" -le "$rounds" ]; do
    order="$trees"
    [ $((r % 2)) -eq 0 ] && order="$(echo $trees | tr ' ' '\n' | tail -r | tr '\n' ' ')"
    for test in $(echo "$tests" | tr , ' '); do
        for tree in $order; do
            before=$(sysctl -n vm.loadavg)
            (cd "$D/$tree/examples/benchmarks" && "$D/venv-$tree/bin/python" benchmark.py --platform Metal \
                --precision single --test "$test" --seconds "$seconds" --style table --outfile "$out/$tree-$test-round$r.json" 2>&1 | grep -v Warning)
            echo "round $r $test $tree before $before after $(sysctl -n vm.loadavg)" >> "$out/loads.txt"
            grep -q ns_per_day "$out/$tree-$test-round$r.json" || echo "no result: round $r $test $tree" | tee -a "$out/loads.txt"
        done
    done
    r=$((r+1))
done
echo "$out"

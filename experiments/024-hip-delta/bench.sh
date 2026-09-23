#!/bin/sh
# Runs on the mini: interleaved benchmark.py rounds of this tree (hipdelta) and the metal
# reference build (hipdelta-ref), alternating which goes first. benchmark.py times with the
# host clock (datetime.now() around step() plus a getState() sync).
# usage: bench.sh <rounds> <seconds> <tests>
set -eu
rounds="$1"
seconds="$2"
tests="$3"
out="$HOME/lab/024-hip-delta/bench-$(date -u +%Y%m%dT%H%MZ)"
mkdir -p "$out"
r=1
while [ "$r" -le "$rounds" ]; do
    order="hipdelta hipdelta-ref"
    [ $((r % 2)) -eq 0 ] && order="hipdelta-ref hipdelta"
    for tree in $order; do
        venv=venv
        [ "$tree" = hipdelta-ref ] && venv=venv-ref
        (cd "$HOME/lab/$tree/examples/benchmarks" && "$HOME/lab/hipdelta/build/$venv/bin/python" benchmark.py --platform Metal \
            --precision single --test "$tests" --seconds "$seconds" --style table --outfile "$out/$tree-round$r.json" 2>&1 | grep -v Warning)
    done
    r=$((r+1))
done
echo "$out"

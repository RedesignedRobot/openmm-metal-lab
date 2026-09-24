#!/bin/sh
# Runs on the mini: interleaved benchmark.py rounds of several variants, reversing their order
# every other round. A variant is label=tree or label=tree:VAR=value,VAR=value. The tree
# hipdelta-ref uses venv-ref, and every other tree uses venv. benchmark.py times with the host
# clock (datetime.now() around step() plus a getState() sync). PRECISION sets --precision, default single.
# usage: ab.sh <rounds> <seconds> <tests> <variant>...
set -eu
rounds="$1"
seconds="$2"
tests="$3"
shift 3
out="$HOME/lab/024-hip-delta/bench-$(date -u +%Y%m%dT%H%MZ)"
mkdir -p "$out"
variants="$*"
reversed="$(echo $variants | tr ' ' '\n' | tail -r | tr '\n' ' ')"
r=1
while [ "$r" -le "$rounds" ]; do
    order="$variants"
    [ $((r % 2)) -eq 0 ] && order="$reversed"
    for variant in $order; do
        label="${variant%%=*}"
        spec="${variant#*=}"
        tree="${spec%%:*}"
        settings=""
        [ "$spec" != "$tree" ] && settings="$(echo "${spec#*:}" | tr , ' ')"
        venv=venv
        [ "$tree" = hipdelta-ref ] && venv=venv-ref
        (cd "$HOME/lab/$tree/examples/benchmarks" && env $settings "$HOME/lab/hipdelta/build/$venv/bin/python" benchmark.py \
            --platform Metal --precision "${PRECISION:-single}" --test "$tests" --seconds "$seconds" --style table \
            --outfile "$out/$label-round$r.json" 2>&1 | grep -v Warning)
    done
    r=$((r+1))
done
echo "$out"

#!/bin/sh
# Constraint accuracy after 200 benchmark.py steps, mixed, for several builds. Run under lease.sh at nice 0.
# usage: checks.sh <out.jsonl> <label=python>...
set -eu
nice_value=$(ps -o nice= -p $$ | tr -d ' ')
[ "$nice_value" = 0 ] || { echo "running at nice $nice_value, not 0" >&2; exit 2; }
unset PYTHONPATH
out="$1"; shift
for case in "pme 1e-5" "gbsa 1e-5" "pme 1e-8" "gbsa 1e-8"; do
    set -- $case "$@"
    test="$1"; tol="$2"; shift 2
    for config in "$@"; do
        label="${config%%=*}"; python="${config#*=}"
        line="$(cd / && "$python" /tmp/openmm-metal-bench/ultra-mixed/constraints.py /tmp/openmm-metal-bench/ultra-base/benchmarks "$test" mixed "$tol" 200)" || line="{\"error\": \"$test $tol\"}"
        echo "{\"label\": \"$label\", $(echo "$line" | cut -c2-)" | tee -a "$out"
    done
done

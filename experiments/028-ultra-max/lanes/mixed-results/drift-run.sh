#!/bin/sh
# NVE drift runs for several builds, interleaved per (test, seed). Run under lease.sh at nice 0.
# DRIFT_CASES overrides the cases: a comma list of "<test> <seed> <tolerance>".
# usage: drift-run.sh <out.jsonl> <ps> <verlet|vv> <label=python>...
set -eu
nice_value=$(ps -o nice= -p $$ | tr -d ' ')
[ "$nice_value" = 0 ] || { echo "running at nice $nice_value, not 0" >&2; exit 2; }
unset PYTHONPATH
out="$1"; ps="$2"; kind="$3"; shift 3
cases="${DRIFT_CASES:-gbsa 1 1e-5,amber20-dhfr 1 1e-5,gbsa 2 1e-5,amber20-dhfr 2 1e-5,gbsa 1 1e-7,amber20-dhfr 1 1e-7}"
echo "$cases" | tr , '\n' | while read -r test seed tol; do
    for config in "$@"; do
        label="${config%%=*}"; python="${config#*=}"
        line="$(cd / && "$python" /tmp/openmm-metal-bench/ultra-mixed/drift.py /tmp/openmm-metal-bench/ultra-base/benchmarks "$test" mixed "$ps" "$seed" "$tol" "$kind")" || line="{\"error\": \"$test $seed $tol\"}"
        echo "{\"label\": \"$label\", $(echo "$line" | cut -c2-)" | tee -a "$out"
    done
done

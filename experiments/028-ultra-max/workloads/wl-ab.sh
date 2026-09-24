#!/bin/sh
# Workloads lane driver: ab.sh's loop plus the RULES.md pre-timing checks. Before every (round, test)
# it waits until no build runs (pgrep clang, clang++, ninja, cc1plus) and logs the top CPU consumers.
# Then it calls ultra-tools/ab-test.sh under lease.sh, with the configuration order reversed every
# other round. Configurations use ab.sh's syntax: label=python:platform:precision[:VAR=value,...].
# usage: wl-ab.sh <outdir> <rounds> <seconds> <tests> <configuration>...
set -eu
TOOLS=/tmp/openmm-metal-bench/ultra-tools
BENCH=/tmp/openmm-metal-bench/ultra-base/benchmarks
unset PYTHONPATH
[ "$(ps -o nice= -p $$ | tr -d ' ')" = 0 ] || { echo "not at nice 0" >&2; exit 2; }
out="${1%/}"; rounds="$2"; seconds="$3"; tests="$(echo "$4" | tr , ' ')"; shift 4
mkdir -p "$out"
[ -z "$(ls -A "$out")" ] || { echo "$out is not empty" >&2; exit 2; }
for config in "$@"; do
    python="$(echo "${config#*=}" | cut -d: -f1)"
    echo "$config $(cd / && "$python" -c 'import openmm; print(openmm.__file__, openmm.version.git_revision)')" >> "$out/configs.txt"
done
reversed="$(echo "$@" | tr ' ' '\n' | tail -r | tr '\n' ' ')"
cd "$BENCH"
r=1
while [ "$r" -le "$rounds" ]; do
    order="$*"
    [ $((r % 2)) -eq 0 ] && order="$reversed"
    for test in $tests; do
        while pgrep -x clang >/dev/null || pgrep -x "clang\\+\\+" >/dev/null || pgrep -x ninja >/dev/null || pgrep -x cc1plus >/dev/null; do
            echo "$(date -u +%H:%M:%SZ) build running, waiting" >> "$out/waits.txt"
            sleep 30
        done
        { echo "== $(date -u +%Y-%m-%dT%H:%M:%SZ) round $r $test load $(sysctl -n vm.loadavg)"; ps -axo pcpu,nice,command -r | head -6 | cut -c1-160; } >> "$out/top.txt"
        export AB_OUT="$out" AB_ROUND="$r" AB_TEST="$test" AB_SECONDS="$seconds"
        "$TOOLS/lease.sh" ultra-workloads "wl-ab.sh $out round $r $test" /bin/sh -c '
            for p in clang "clang\\+\\+" ninja cc1plus; do pgrep -x $p >/dev/null && echo "$(date -u +%H:%M:%SZ) BUILD OVERLAP $p at lease start round $AB_ROUND $AB_TEST" >> "$AB_OUT/waits.txt"; done
            exec "$0" "$@"' "$TOOLS/ab-test.sh" $order
        for p in clang "clang\\+\\+" ninja cc1plus; do pgrep -x $p >/dev/null && echo "$(date -u +%H:%M:%SZ) BUILD OVERLAP $p at end round $r $test" >> "$out/waits.txt"; done
        true
    done
    r=$((r+1))
done
echo "done $out"

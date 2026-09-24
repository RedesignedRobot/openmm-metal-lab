#!/bin/sh
# Runs on the M3 Ultra at nice 0: the quiet-window benchmark. 3 rounds of 30 s through ab.sh, after a
# preflight that waits (up to 20 minutes) until the 1 minute load is under 3, no build runs and the
# lease queue is empty, and logs the machine state to <outdir>/preflight.txt. Each build is
# name=dir:precisions, with precisions from single, mixed and opencl. The first build is the
# baseline; its opencl run is the denominator for every Metal/OpenCL ratio. Ratios printed at the
# end: each Metal configuration against the baseline's OpenCL, and each build's configurations
# against the baseline's same configuration.
# --estimate prints the expected wall time and exits, from per-run times measured on the M3 Ultra.
# --rounds N changes the 3 rounds. --smoke is the end-to-end check of this script: 1 round of 5 s,
# with at most 30 s of preflight.
# While the preflight waits, it prints the queued tickets, so their owners can be asked to leave.
#   qw.sh /tmp/openmm-metal-bench/ultra-integrated/qw1 all base=/tmp/openmm-metal-bench/ultra-base:single,mixed,opencl int=/tmp/openmm-metal-bench/ultra-integrated:single,mixed
# usage: qw.sh [--estimate] [--rounds N | --smoke] <outdir> <tests|all> <name=dir:precisions>...
set -eu
TOOLS=/tmp/openmm-metal-bench/ultra-tools
ALL=gbsa,rf,pme,apoa1rf,apoa1pme,apoa1ljpme,amber20-dhfr,amber20-cellulose,amber20-stmv
USAGE="usage: qw.sh [--estimate] [--rounds N | --smoke] <outdir> <tests|all> <name=dir:precisions>..."
rounds=3
seconds=30
LOAD_MAX=3
preflight_max=1200
BUILDS='clang|clang\+\+|ninja|cc1plus'
estimate=0
while :; do
    case "${1:-}" in
    --estimate) estimate=1; shift ;;
    --rounds) rounds="${2:-}"; shift 2 ;;
    --smoke) rounds=1; seconds=5; preflight_max=30; shift ;;
    *) break ;;
    esac
done
case "$rounds" in ''|*[!0-9]*|0) echo "$USAGE" >&2; exit 2 ;; esac
[ $# -ge 3 ] || { echo "$USAGE" >&2; exit 2; }
out="$1"
tests="$2"
[ "$tests" = all ] && tests=$ALL
shift 2

configs=""
pairs=""
base=""
for build in "$@"; do
    name="${build%%=*}"
    dir="${build#*=}"
    precisions="${dir##*:}"
    dir="${dir%:*}"
    [ -x "$dir/venv/bin/python" ] || { echo "$dir/venv/bin/python is missing" >&2; exit 2; }
    [ -n "$base" ] || base="$name"
    for precision in $(echo "$precisions" | tr , ' '); do
        case "$precision" in
        single|mixed) platform=Metal ;;
        opencl) platform=OpenCL ;;
        *) echo "unknown precision $precision in $build" >&2; exit 2 ;;
        esac
        label="$name-$precision"
        configs="$configs $label=$dir/venv/bin/python:$platform:$([ $precision = opencl ] && echo single || echo $precision)"
        [ $platform = Metal ] && pairs="$pairs $label/$base-opencl"
        [ "$name" != "$base" ] && pairs="$pairs $label/$base-$precision"
    done
done

# Seconds per 30 s run for each test, from ab.sh runs on the M3 Ultra (025's rounds; stmv from 028).
per_run() {
    case "$1:$2" in
    amber20-cellulose:mixed) echo 77 ;;
    amber20-cellulose:*) echo 42 ;;
    amber20-stmv:*) echo 90 ;;
    amber20-dhfr:*|apoa1*:*) echo 34 ;;
    *) echo 32 ;;
    esac
}
total=0
for test in $(echo "$tests" | tr , ' '); do
    for config in $configs; do
        label="${config%%=*}"
        total=$((total + $(per_run "$test" "${label##*-}") - 30 + seconds))
    done
done
total=$((total * rounds))
echo "estimate: $rounds rounds of $seconds s, $(echo $configs | wc -w | tr -d ' ') configurations, $(echo "$tests" | tr , ' ' | wc -w | tr -d ' ') tests, about $((total / 60)) minutes"
[ $estimate = 1 ] && exit 0

nice_value=$(ps -o nice= -p $$ | tr -d ' ')
[ "$nice_value" = 0 ] || { echo "running at nice $nice_value, not 0: launch through /bin/sh -c 'nohup ...'" >&2; exit 2; }
mkdir -p "$out"
[ -z "$(ls -A "$out")" ] || { echo "$out is not empty; use a new outdir" >&2; exit 2; }
waited=0
while :; do
    load="$(sysctl -n vm.loadavg | awk '{ print $2 }')"
    builds="$(pgrep -x "$BUILDS" | wc -l | tr -d ' ')"
    queue="$("$TOOLS/lease.sh" --status | grep -c '^  [0-9][0-9]*-.*  waiting ' || true)"
    held="$([ -d /tmp/openmm-lease ] && echo 1 || echo 0)"
    quiet="$(awk -v l="$load" -v m=$LOAD_MAX 'BEGIN { print (l < m) }')"
    [ "$quiet" = 1 ] && [ "$builds" = 0 ] && [ "$queue" = 0 ] && [ "$held" = 0 ] && break
    if [ $waited -ge $preflight_max ]; then
        echo "preflight: not quiet after $waited s (load $load, $builds build processes, $queue queued, lease held $held); starting anyway" | tee -a "$out/preflight.txt"
        break
    fi
    if [ $((waited % 60)) -eq 0 ]; then
        echo "$(date -u +%H:%M:%SZ) preflight waiting: load $load, $builds build processes, $queue queued, lease held $held"
        "$TOOLS/lease.sh" --status | sed -n '/^holder: [^n]/p; /^  /p'
    fi
    sleep 10
    waited=$((waited+10))
done
{
    echo "start $(date -u +%Y-%m-%dT%H:%M:%SZ) after $waited s of preflight, load $(sysctl -n vm.loadavg)"
    "$TOOLS/lease.sh" --status
    ps -Aro pcpu,pid,command | head -11 | cut -c1-160
} >> "$out/preflight.txt" 2>&1
cat "$out/preflight.txt"
"$TOOLS/ab.sh" "$out/ab" $rounds $seconds "$tests" $configs
echo "end $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$out/preflight.txt"
/tmp/openmm-metal-bench/ultra-base/venv/bin/python "$TOOLS/summarize.py" "$out/ab" $pairs | tee "$out/summary.txt"

#!/bin/sh
# Runs on the M3 Ultra at nice 0: a dedicated benchmark window, for the lead and infra only.
# 1. Queues for the GPU lease with a ticket dated just before the oldest queued ticket, so it starts
#    when the current hold ends and every queued ticket keeps its place behind it. It holds the lease
#    for the whole window (lease.sh --cap: twice the estimate plus the preflight plus 10 minutes, in
#    place of the 20 minute cap), which blocks every lane's GPU work, and puts up /tmp/openmm-window:
#    build.sh waits while it exists, and RULES.md tells lanes not to build. Releasing the lease at the
#    end reopens the queue. Nothing of anyone else's is stopped: the background VM and other jobs run
#    on and are logged.
# 2. Preflight inside the hold (which pauses build.sh's builds): waits up to 10 minutes for other builds to end and the 1 minute
#    load to fall under 3, then logs the lease queue and the top CPU processes to preflight.txt.
# 3. <rounds> rounds of <seconds> s through ab.sh, all configurations interleaved. Every run logs the
#    load and the background VM's CPU first. A (round, test) with a run that overlapped a build runs
#    again at the end (ab.sh --rerun-builds). Then summary.txt.
# 4. With --cpu, the CPU baselines: <rounds> rounds of <seconds> s of pme, apoa1pme and amber20-dhfr on
#    the baseline build's CPU platform (mixed) into <outdir>/cpu, then cpu-summary.txt. The main
#    screen has the same tests on Metal in the same hold. ab.sh reruns a CPU run beside a process
#    over 100% once at the end; one still marked stays, flagged in cpu-summary.txt with that process's
#    name and peak %CPU. The first window needs it once.
# Each build is name=dir:precisions, with precisions from single, mixed and opencl. The first build
# is the baseline; its opencl run is the denominator of every Metal/OpenCL ratio. summary.txt has each
# Metal configuration against the baseline's OpenCL, and each other build against the baseline's same
# configuration. A pair whose baseline label doesn't exist (no opencl, or a precision the baseline
# lacks) is left out, so summary.txt is still written.
# --estimate prints the expected wall time and exits. --rounds N changes the 3 rounds. --smoke is the
# end-to-end check of this script: 1 round of 5 s, at most 1 minute of preflight.
# The outdir may hold other files (a launcher's log or sampler), but not this script's own outputs from
# an earlier window: ab/, cpu/, summary.txt, cpu-summary.txt or preflight.txt.
# Under a gpuq job (GPUQ_JOB set, as in `gpuq submit --class window`), it exits 2 at once when the job's
# cap has less time left than the estimate plus the preflight, instead of being killed at the cap.
# Each build.sh tree (one with build/) must have a BUILT whose src hash matches its src, and pass check-pin.py,
# before the window queues. GPUQ_PREFLIGHT=1 (gpuq submit sets it) runs every check, with GPUQ_PREFLIGHT_CAP
# as the job's cap, then exits 0 before queuing or writing anything.
#   /bin/sh -c 'nohup /tmp/openmm-metal-bench/ultra-tools/window.sh /tmp/openmm-metal-bench/ultra-infra/w1 all base=/tmp/openmm-metal-bench/ultra-base:single,mixed,opencl int=/tmp/openmm-metal-bench/ultra-integrated:single,mixed > /tmp/openmm-metal-bench/ultra-infra/w1.out 2>&1 < /dev/null &'
# usage: window.sh [--estimate] [--cpu] [--rounds N | --smoke] <outdir> <tests|all> <name=dir:precisions>...
set -eu
export LC_ALL=C
TOOLS=/tmp/openmm-metal-bench/ultra-tools
QUEUE=/tmp/openmm-lease-queue
WINDOW=/tmp/openmm-window
TICKET='[0-9]+-[A-Za-z0-9_.-]+-[0-9]+'
ALL=gbsa,rf,pme,apoa1rf,apoa1pme,apoa1ljpme,amber20-dhfr,amber20-cellulose,amber20-stmv
USAGE="usage: window.sh [--estimate] [--cpu] [--rounds N | --smoke] <outdir> <tests|all> <name=dir:precisions>..."
CPU_TESTS=pme,apoa1pme,amber20-dhfr
LOAD_MAX=3
BUILDS='clang|clang\+\+|ninja|cc1plus'

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

# Sets rounds, seconds, preflight_max, estimate, cpu, out, tests, configs, pairs, base_dir and total from the
# arguments, leaving the script's own "$@" for the re-run under the lease.
parse() {
    rounds=3
    seconds=30
    preflight_max=600
    estimate=0
    cpu=0
    while :; do
        case "${1:-}" in
        --estimate) estimate=1; shift ;;
        --cpu) cpu=1; shift ;;
        --rounds) rounds="${2:-}"; shift 2 ;;
        --smoke) rounds=1; seconds=5; preflight_max=60; shift ;;
        *) break ;;
        esac
    done
    case "$rounds" in ''|*[!0-9]*|0) echo "$USAGE" >&2; exit 2 ;; esac
    [ $# -ge 3 ] || { echo "$USAGE" >&2; exit 2; }
    case "$1" in
    /*) out="${1%/}" ;;
    *) echo "the outdir must be an absolute path" >&2; exit 2 ;;
    esac
    tests="$2"
    [ "$tests" = all ] && tests=$ALL
    shift 2
    configs=""
    pairs=""
    dirs=""
    base=""
    for build in "$@"; do
        name="${build%%=*}"
        dir="${build#*=}"
        precisions="${dir##*:}"
        dir="${dir%:*}"
        [ -x "$dir/venv/bin/python" ] || { echo "$dir/venv/bin/python is missing" >&2; exit 2; }
        dirs="$dirs $dir"
        [ -n "$base" ] || { base="$name"; base_dir="$dir"; base_precisions=",$precisions,"; }
        for precision in $(echo "$precisions" | tr , ' '); do
            case "$precision" in
            single|mixed) platform=Metal ;;
            opencl) platform=OpenCL ;;
            *) echo "unknown precision $precision in $build" >&2; exit 2 ;;
            esac
            label="$name-$precision"
            configs="$configs $label=$dir/venv/bin/python:$platform:$([ $precision = opencl ] && echo single || echo $precision)"
            case "$base_precisions" in *,opencl,*) [ $platform = Metal ] && pairs="$pairs $label/$base-opencl" ;; esac
            case "$base_precisions" in *,$precision,*) [ "$name" != "$base" ] && pairs="$pairs $label/$base-$precision" ;; esac
        done
    done
    total=0
    for test in $(echo "$tests" | tr , ' '); do
        for config in $configs; do
            label="${config%%=*}"
            total=$((total + $(per_run "$test" "${label##*-}") - 30 + seconds))
        done
    done
    total=$((total * rounds))
    [ $cpu = 1 ] || return 0
    # A CPU-platform run times up to twice <seconds> (benchmark.py's step count overshoots).
    for test in $(echo "$CPU_TESTS" | tr , ' '); do
        total=$((total + rounds * ($(per_run "$test" mixed) - 30 + 2 * seconds)))
    done
}

parse "$@"
[ -n "${OPENMM_WINDOW:-}" ] || echo "estimate: $rounds rounds of $seconds s, $(echo $configs | wc -w | tr -d ' ') configurations, $(echo "$tests" | tr , ' ' | wc -w | tr -d ' ') tests$([ $cpu = 1 ] && echo ", the CPU arm"), about $((total / 60)) minutes"
[ $estimate = 1 ] && exit 0
nice_value=$(ps -o nice= -p $$ | tr -d ' ')
[ -n "${GPUQ_PREFLIGHT:-}" ] || [ "$nice_value" = 0 ] || { echo "running at nice $nice_value, not 0: launch through /bin/sh -c 'nohup ...'" >&2; exit 2; }
if [ -n "${GPUQ_JOB:-}" ] || [ -n "${GPUQ_PREFLIGHT_CAP:-}" ]; then
    need=$((total + preflight_max))
    left="${GPUQ_PREFLIGHT_CAP:-}"
    [ -n "$left" ] || left="$(/tmp/openmm-metal-bench/env/bin/python3 "$TOOLS/gpuq/gpuq" status "$GPUQ_JOB" 2>/dev/null | sed -n 's/^cap left: \(-*[0-9]*\) s$/\1/p')"
    if [ -n "$left" ] && [ "$left" -lt "$need" ]; then
        echo "gpuq job ${GPUQ_JOB:-being submitted} has $left s of its cap left, under this window's $need s (estimate $total s plus $preflight_max s of preflight): it would be killed at the cap. Resubmit with --est $((need / 60 + 1))m (the default cap is then 2 x est + 20 min) or a larger --cap." >&2
        exit 2
    fi
fi

if [ -z "${OPENMM_WINDOW:-}" ]; then
    for own in ab cpu summary.txt cpu-summary.txt preflight.txt; do
        [ ! -e "$out/$own" ] || { echo "$out already holds $own from an earlier window; use a new outdir" >&2; exit 2; }
    done
    for dir in $dirs; do
        [ -d "$dir/build" ] || continue
        [ -f "$dir/BUILT" ] || { echo "$dir/BUILT is missing: a build.sh is running there, or the last one failed" >&2; exit 2; }
        [ "$(sed -n 's/^src //p' "$dir/BUILT")" = "$("$TOOLS/srchash.sh" "$dir")" ] \
            || { echo "$dir/src changed after build.sh; rebuild before the window" >&2; exit 2; }
        /tmp/openmm-metal-bench/env/bin/python3 "$TOOLS/check-pin.py" "$dir" || exit 2
    done
    [ -z "${GPUQ_PREFLIGHT:-}" ] || { echo "preflight ok: window.sh $out"; exit 0; }
    mkdir -p "$out"
    # Merge-path tickets (leading 0) stay ahead of the window; it goes next among the rest.
    oldest="$(ls "$QUEUE" 2>/dev/null | grep -xE "$TICKET" | grep -v '^0' | sort | head -1 | cut -d- -f1)"
    ticket_us="$(perl -MTime::HiRes=gettimeofday -e '($s, $us) = gettimeofday; printf "%d%06d\n", $s, $us')"
    [ -n "$oldest" ] && ticket_us=$((oldest - 1))
    echo "$(date -u +%H:%M:%SZ) queueing ahead of $(ls "$QUEUE" 2>/dev/null | grep -xE "$TICKET" | grep -vc '^0' || true) tickets, behind $(ls "$QUEUE" 2>/dev/null | grep -xE "$TICKET" | grep -c '^0' || true) merge-path tickets and the current hold: $("$TOOLS/lease.sh" --status | head -1)"
    OPENMM_WINDOW=1 LEASE_TICKET_US=$ticket_us exec "$TOOLS/lease.sh" --cap $((2 * total + preflight_max + 600)) window \
        "dedicated window $out, about $((total / 60)) min; lanes wait, build.sh waits" "$0" "$@"
fi

echo "$$ $(date -u +%Y-%m-%dT%H:%M:%SZ) $out" > "$WINDOW"
trap '[ "$(cut -d" " -f1 "$WINDOW" 2>/dev/null)" = $$ ] && rm -f "$WINDOW" || true' EXIT
echo "$(date -u +%H:%M:%SZ) holding the lease; /tmp/openmm-window is up"
waited=0
while :; do
    load="$(sysctl -n vm.loadavg | awk '{ print $2 }')"
    builds="$(ps -axo stat=,ucomm= | awk '$1 !~ /^T/ && $2 ~ /^('"$BUILDS"')$/' | wc -l | tr -d ' ')"
    quiet="$(awk -v l="$load" -v m=$LOAD_MAX 'BEGIN { print (l < m) }')"
    [ "$quiet" = 1 ] && [ "$builds" = 0 ] && break
    if [ $waited -ge $preflight_max ]; then
        echo "preflight: not quiet after $waited s (load $load, $builds build processes); starting anyway" >> "$out/preflight.txt"
        break
    fi
    [ $((waited % 60)) -eq 0 ] && echo "$(date -u +%H:%M:%SZ) preflight waiting: load $load, $builds build processes"
    sleep 10
    waited=$((waited+10))
done
{
    echo "start $(date -u +%Y-%m-%dT%H:%M:%SZ) after $waited s of preflight, load $(sysctl -n vm.loadavg)"
    "$TOOLS/lease.sh" --status
    ps -Aro pcpu,pid,command | head -11 | cut -c1-160
} >> "$out/preflight.txt" 2>&1
cat "$out/preflight.txt"
"$TOOLS/ab.sh" --rerun-builds "$out/ab" $rounds $seconds "$tests" $configs
echo "end $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$out/preflight.txt"
/tmp/openmm-metal-bench/ultra-base/venv/bin/python "$TOOLS/summarize.py" "$out/ab" $pairs | tee "$out/summary.txt"
[ $cpu = 1 ] || exit 0
"$TOOLS/ab.sh" --rerun-builds "$out/cpu" $rounds $seconds $CPU_TESTS "$base-cpu=$base_dir/venv/bin/python:CPU:mixed"
/tmp/openmm-metal-bench/ultra-base/venv/bin/python "$TOOLS/summarize.py" "$out/cpu" | tee "$out/cpu-summary.txt"

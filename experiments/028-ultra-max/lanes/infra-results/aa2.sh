#!/bin/sh
# Runs inside one lease.sh timing hold on the M3 Ultra: A/A2 of build.sh's effect on timings. The same ultra-base
# build runs as a and b, 30 s per run, on rf single, gbsa single and amber20-cellulose mixed, in 8 rounds that
# alternate quiet and build (q b q b q b q b). A quiet round starts only with 0 build processes and a 1-minute load
# under 3. A build round runs beside one build-aa.sh build (taskpolicy -b, nice 10, -j8) of a scratch copy of
# ultra-base's src, cleaned and restarted whenever it finishes, and stopped (by its process group) before each quiet
# round. /tmp/openmm-window, with this script's pid, keeps build.sh waiters off throughout.
# Result: per test, build/quiet of the a/b mean for each of the 4 pairs, median and range. Pass: within 1% on all 3.
# usage: aa2.sh
set -u
B=/tmp/openmm-metal-bench
AA=$B/ultra-infra/aa2
S=$B/ultra-infra-aa
PY=$B/ultra-base/venv/bin/python
WINDOW=/tmp/openmm-window
build_sh=$B/ultra-infra/build-aa.sh
SECONDS_PER_RUN=30
QUIET_LOAD=3
bpid=
echo "$$ $(date -u +%Y-%m-%dT%H:%M:%SZ) infra A/A2, quiet and build rounds (not a window)" > "$WINDOW"
stop_build() {
    [ -n "$bpid" ] || return 0
    kill -TERM -"$bpid" 2>/dev/null
    i=0
    while ps -A -o pgid= | grep -qx " *$bpid"; do
        i=$((i + 1))
        [ $i -lt 30 ] || kill -KILL -"$bpid" 2>/dev/null
        sleep 1
    done
    bpid=
}
trap 'stop_build; [ "$(cut -d" " -f1 "$WINDOW" 2>/dev/null)" = $$ ] && rm -f "$WINDOW"' EXIT
trap 'exit 1' INT TERM HUP
mkdir -p "$AA"
echo "$(date -u +%H:%M:%SZ) /tmp/openmm-window is up"
builds() { pgrep -x 'clang|clang\+\+|ninja|cc1plus' | wc -l | tr -d ' '; }
load1() { sysctl -n vm.loadavg | awk '{ print $2 }'; }
group_compilers() { ps -A -o pgid=,comm= | awk -v g="$bpid" '$1 == g && $2 ~ /(^|\/)(clang|clang\+\+)$/ { n++ } END { print n + 0 }'; }
cpu() {
    echo "$(date -u +%H:%M:%SZ) load $(sysctl -n vm.loadavg); build processes $(builds); our compilers $(group_compilers); all build processes %cpu $(ps -A -o %cpu=,comm= | awk '$2 ~ /(^|\/)(clang|clang\+\+|ninja|cc1plus)$/ {s += $1} END {printf "%.0f", s}')"
}
# job control gives the build its own process group, so it can be counted and stopped as one
start_build() {
    [ -f "$S/BUILT" ] && taskpolicy -b ninja -C "$S/build" -t clean > /dev/null
    set -m
    $build_sh $S > $S/build.out 2>&1 < /dev/null &
    bpid=$!
    set +m
    echo "$(date -u +%H:%M:%SZ) build $bpid started"
}
# Waits until the build compiles near -j8, at most 120 s.
warm_build() {
    i=0
    while [ "$(group_compilers)" -lt 6 ] && [ $i -lt 60 ]; do
        kill -0 "$bpid" 2>/dev/null || start_build
        sleep 2
        i=$((i + 1))
    done
}
run_round() {
    $B/ultra-tools/ab.sh "$AA/r$1-$2-single" 1 $SECONDS_PER_RUN rf,gbsa a=$PY:Metal:single b=$PY:Metal:single
    $B/ultra-tools/ab.sh "$AA/r$1-$2-mixed" 1 $SECONDS_PER_RUN amber20-cellulose a=$PY:Metal:mixed b=$PY:Metal:mixed
}
for r in 1 2 3 4 5 6 7 8; do
    if [ $((r % 2)) = 1 ]; then
        kind=q
        stop_build
        told=
        until [ "$(builds)" = 0 ] && awk -v l="$(load1)" -v m=$QUIET_LOAD 'BEGIN { exit !(l < m) }'; do
            [ -n "$told" ] || echo "$(date -u +%H:%M:%SZ) waiting for 0 build processes (now $(builds)) and load under $QUIET_LOAD (now $(load1))"
            told=1
            sleep 5
        done
        cpu
        echo "$(date -u +%H:%M:%SZ) round $r, quiet"
        run_round $r $kind
    else
        kind=b
        kill -0 "${bpid:-0}" 2>/dev/null || start_build
        warm_build
        cpu
        echo "$(date -u +%H:%M:%SZ) round $r, build compiling"
        run_round $r $kind &
        abpid=$!
        # Restarts the build whenever it finishes while the round runs; logs the machine 20 s in.
        i=0
        while kill -0 $abpid 2>/dev/null; do
            kill -0 "$bpid" 2>/dev/null || { echo "$(date -u +%H:%M:%SZ) build finished; cleaning and restarting"; start_build; }
            i=$((i + 1))
            [ $i != 10 ] || cpu
            sleep 2
        done
        wait $abpid
        cpu
    fi
done
stop_build
"$PY" - "$AA" <<'PY'
import json, glob, os, statistics, sys
aa = sys.argv[1]
def mean_ns(round_, kind, test):
    prec = "mixed" if test == "amber20-cellulose" else "single"
    vals = []
    for f in glob.glob(f"{aa}/r{round_}-{kind}-{prec}/*-{test}-round1.json"):
        vals += [b["ns_per_day"] for b in json.load(open(f))["benchmarks"]]
    return statistics.mean(vals) if len(vals) == 2 else None
worst = 0
for test in ["rf", "gbsa", "amber20-cellulose"]:
    pairs = [(mean_ns(q, "q", test), mean_ns(q + 1, "b", test)) for q in (1, 3, 5, 7)]
    ratios = [b / q for q, b in pairs if q and b]
    rounds = " ".join(f"{q:.1f}/{b:.1f}" if q and b else "missing" for q, b in pairs)
    if len(ratios) < 4:
        print(f"{test:18s} missing results: {rounds}")
        worst = 9
        continue
    med = statistics.median(ratios)
    worst = max(worst, abs(med - 1))
    print(f"{test:18s} build/quiet {med:.3f} (pairs {min(ratios):.3f}..{max(ratios):.3f}); quiet/build ns/day {rounds}")
print("A/A2", "PASS" if worst <= 0.01 else "FAIL", f"(largest |median - 1| {worst:.3f}, bar 0.010)")
PY
echo "$(date -u +%H:%M:%SZ) AA2 DONE"

#!/bin/sh
# Runs on the M2 at nice 0: the M2 check of one or more candidates against base, all m2build.sh trees.
# Several candidates share one interleaved session, so base runs once per (round, test, precision).
# 1. Forces gate: forces.py, Metal single and mixed against Reference on gbsa, rf, pme, apoa1rf,
#    apoa1pme and apoa1ljpme, compared with base/forces.txt (the M2 base baseline; forces.py has the
#    rule). With --baseline and no candidate it writes base/forces.txt instead.
# 2. Interleaved A/B: base and each candidate, Metal single and Metal mixed, every (round, test,
#    configuration) a fresh benchmark.py process from base/benchmarks, order reversed every other
#    round. benchmark.py times with the host clock: datetime.now() around step().
#    Each run goes through /usr/bin/time -l (peak memory footprint and maximum resident set size).
#    Before each run: wait up to 5 minutes for any build to end, then log the 1-minute load,
#    memory_pressure's free percentage, swap use, Spotlight's CPU (mds, mds_stores and mdworker
#    processes, summed) and the top 5 CPU processes to loads.txt.
# 3. m2summary.py: one table per candidate (ratios, footprint deltas, gate verdict) in summary.txt.
# Labels are the tree names (base, cand, cand2, ...).
# The GPU lease /tmp/openmm-lease is taken per step (forces) and per (round, test), with an owner
# line "ultra-m2 <UTC time> <what>", and removed on exit; a lease someone else holds is waited on.
# Refuses to run at a nice value other than 0, or on a tree whose src changed after m2build.sh.
# Output goes to /Users/amir/lab/ultra-m2/checks/<UTC time>-<first candidate commit>/. The last line of
# the output is "CHECK DONE <outdir>" or "CHECK FAILED".
#   /bin/sh -c 'nohup /Users/amir/lab/ultra-m2/tools/m2check.sh /Users/amir/lab/ultra-m2/cand > /Users/amir/lab/ultra-m2/cand/check.out 2>&1 < /dev/null &'
# usage: m2check.sh [-r rounds] [-s seconds] [-t tests|all] <candidate dir>...   (defaults 2, 15, all 8)
#        m2check.sh --baseline
set -eu
ROOT=/Users/amir/lab/ultra-m2
BASE=$ROOT/base
TOOLS=$ROOT/tools
BENCH=$BASE/benchmarks
LEASE=/tmp/openmm-lease
BUILDS='clang|clang\+\+|ninja|cc1plus'
BUILD_WAIT_SECONDS=300
ALL_TESTS=gbsa,rf,pme,apoa1rf,apoa1pme,apoa1ljpme,amber20-dhfr,amber20-cellulose
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
unset PYTHONPATH OPENMM_PLUGIN_DIR DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH DYLD_INSERT_LIBRARIES
held=0
trap 'if [ $held = 1 ]; then rm -rf "$LEASE"; fi' EXIT
trap 'exit 1' INT TERM HUP
nice_value=$(ps -o nice= -p $$ | tr -d ' ')
[ "$nice_value" = 0 ] || { echo "running at nice $nice_value, not 0: launch through /bin/sh -c 'nohup ...'" >&2; echo "CHECK FAILED"; exit 2; }

fail() { echo "$*" >&2; echo "CHECK FAILED"; exit 2; }
utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
free_pct() { memory_pressure -Q | sed -n 's/.*free percentage: \([0-9]*\)%.*/\1/p'; }
spotlight_pct() { ps -Aco pcpu=,comm= | awk '$2 ~ /^(mds|mds_stores|mdworker|mdworker_shared|mdsync|mdbulkimport)$/ { s += $1 } END { printf "%.0f", s }'; }
check_tree() {
    [ -x "$1/venv/bin/python" ] && [ -f "$1/BUILT" ] || fail "$1 has no venv or BUILT: m2build.sh is running there, or failed"
    now_hash="$(cd "$1/src" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum | shasum | cut -c1-40)"
    [ "$(sed -n 's/^src //p' "$1/BUILT")" = "$now_hash" ] || fail "$1/src changed after m2build.sh; rebuild first"
}
take_lease() {
    waited=0
    until mkdir "$LEASE" 2>/dev/null; do
        [ $((waited % 300)) -eq 0 ] && echo "$(utc) waiting for the lease, held by: $(cat "$LEASE/owner" 2>/dev/null || echo unknown)"
        sleep 2
        waited=$((waited+2))
    done
    held=1
    echo "ultra-m2 $(utc) $1" > "$LEASE/owner"
    [ $waited -gt 0 ] && echo "$(utc) lease taken after ${waited}s: $1"
    return 0
}
release_lease() { rm -rf "$LEASE"; held=0; }
# Which openmm, libOpenMM and Metal plugin a python really loads.
describe() {
    (cd / && "$1" - <<'PY'
import ctypes, openmm
from openmm import version
dyld = ctypes.CDLL(None)
dyld._dyld_image_count.restype = ctypes.c_uint32
dyld._dyld_get_image_name.restype = ctypes.c_char_p
images = [dyld._dyld_get_image_name(i).decode() for i in range(dyld._dyld_image_count())]
pick = lambda name: next((p for p in images if p.endswith(name)), "not loaded")
print(openmm.__file__, version.git_revision, "libOpenMM", pick("/libOpenMM.dylib"), "Metal", pick("/libOpenMMMetal.dylib"))
PY
    )
}

if [ "${1:-}" = --baseline ]; then
    check_tree "$BASE"
    take_lease "m2check.sh forces baseline"
    "$BASE/venv/bin/python" "$TOOLS/forces.py" "$BENCH" "$BASE/forces.txt.new" > "$BASE/forces-baseline.log" 2>&1 || { cat "$BASE/forces-baseline.log"; fail "forces.py failed"; }
    release_lease
    mv "$BASE/forces.txt.new" "$BASE/forces.txt"
    printf 'M2 base baseline, %s, %s\n' "$(utc)" "$(sed -n 's/^commit //p' "$BASE/BUILT")" > "$BASE/forces-baseline.txt"
    cat "$BASE/forces.txt" >> "$BASE/forces-baseline.txt"
    cat "$BASE/forces-baseline.txt"
    echo "CHECK DONE $BASE/forces.txt"
    exit 0
fi

rounds=2
seconds=15
tests=$ALL_TESTS
while getopts r:s:t: flag; do
    case $flag in
    r) rounds="$OPTARG" ;;
    s) seconds="$OPTARG" ;;
    t) tests="$OPTARG" ;;
    *) fail "usage: m2check.sh [-r rounds] [-s seconds] [-t tests] <candidate dir>... | m2check.sh --baseline" ;;
    esac
done
shift $((OPTIND-1))
[ $# -ge 1 ] || fail "usage: m2check.sh [-r rounds] [-s seconds] [-t tests] <candidate dir>... | m2check.sh --baseline"
[ "$tests" = all ] && tests=$ALL_TESTS
check_tree "$BASE"
[ -f "$BASE/forces.txt" ] || fail "$BASE/forces.txt is missing: run m2check.sh --baseline"
labels=""
for cand in "$@"; do
    cand="${cand%/}"
    case "$cand" in "$ROOT"/*) ;; *) fail "a candidate dir must be an absolute path under $ROOT, not $cand" ;; esac
    label="$(basename "$cand")"
    case " base $labels " in *" $label "*) fail "two trees are named $label" ;; esac
    check_tree "$cand"
    labels="$labels $label"
done
commit="$(sed -n 's/^commit //p' "$ROOT/$(echo $labels | cut -d' ' -f1)/BUILT")"
out="$ROOT/checks/$(date -u +%Y%m%dT%H%M%SZ)-$(echo "$commit" | cut -c1-9)"
mkdir -p "$out"
start=$(date +%s)
{
    echo "check started $(utc), $rounds rounds of $seconds s, tests $tests"
    echo "clock: benchmark.py host clock, datetime.now() around step()"
    for label in base $labels; do
        echo "$label $ROOT/$label: $(tr '\n' ' ' < "$ROOT/$label/BUILT")"
        echo "  loads $(describe "$ROOT/$label/venv/bin/python")"
    done
} > "$out/configs.txt"
cat "$out/configs.txt"

for label in $labels; do
    t0=$(date +%s)
    take_lease "m2check.sh forces $ROOT/$label"
    gate=PASS
    "$ROOT/$label/venv/bin/python" "$TOOLS/forces.py" "$BENCH" "$out/forces-$label.txt" "$BASE/forces.txt" > "$out/forces-verdict-$label.txt" 2>&1 || gate=FAIL
    release_lease
    grep -q FAIL "$out/forces-verdict-$label.txt" && gate=FAIL
    [ "$(grep -c ' ok$' "$out/forces-verdict-$label.txt" || true)" = 12 ] || gate=FAIL
    echo "$gate" > "$out/gate-$label.txt"
    cat "$out/forces-verdict-$label.txt"
    echo "forces gate $label $gate, $(( $(date +%s) - t0 )) s"
done

order=""
for precision in single mixed; do
    for label in base $labels; do order="$order $label-$precision"; done
done
reversed="$(echo $order | tr ' ' '\n' | tail -r | tr '\n' ' ')"
t0=$(date +%s)
cd "$BENCH"
r=1
while [ $r -le "$rounds" ]; do
    this="$order"
    [ $((r % 2)) -eq 0 ] && this="$reversed"
    for test in $(echo "$tests" | tr , ' '); do
        take_lease "m2check.sh round $r $test"
        for label in $this; do
            python="$ROOT/${label%-*}/venv/bin/python"
            precision="${label##*-}"
            name="$label-$test-round$r"
            waited=0
            while pgrep -x "$BUILDS" > /dev/null && [ $waited -lt $BUILD_WAIT_SECONDS ]; do sleep 5; waited=$((waited+5)); done
            note=""
            pgrep -x "$BUILDS" > /dev/null && note=" BUILD RUNNING after ${waited} s wait"
            top="$(ps -Aro pcpu=,comm= | head -5 | awk '{ cpu = $1; $1 = ""; n = split($0, path, "/"); printf "%s %s%%, ", path[n], cpu }')"
            echo "$(utc) round $r $test $label load $(sysctl -n vm.loadavg | awk '{print $2}') free $(free_pct)% swap $(sysctl -n vm.swapusage | awk '{print $6}')$note spotlight $(spotlight_pct)% top ${top%, }" >> "$out/loads.txt"
            run0=$(date +%s)
            /usr/bin/time -l -o "$out/$name.time" perl -e 'alarm shift; exec @ARGV' $((seconds + 900)) \
                "$python" benchmark.py --platform Metal --precision "$precision" --test "$test" --seconds "$seconds" \
                --style table --outfile "$out/$name.json" > "$out/$name.log" 2>&1 || true
            echo "$(utc) $name $(( $(date +%s) - run0 )) s" >> "$out/durations.txt"
            [ -s "$out/$name.json" ] || echo "$(utc) NO RESULT $name" | tee -a "$out/loads.txt"
        done
        release_lease
    done
    r=$((r+1))
done
echo "A/B $(( $(date +%s) - t0 )) s"
echo "total $(( $(date +%s) - start )) s" >> "$out/configs.txt"
"$BASE/venv/bin/python" "$TOOLS/m2summary.py" "$out" > "$out/summary.txt" 2>&1 || true
cat "$out/summary.txt"
echo "CHECK DONE $out"

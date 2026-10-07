#!/bin/sh
# Runs on the M3 Ultra at nice 0: the correctness gate for a tree that build.sh built.
# 1. forces.py, Metal single and mixed against Reference on gbsa, rf, pme, apoa1rf, apoa1pme and
#    apoa1ljpme, compared with ultra-base/forces.txt (see forces.py for the rule). A minute or two.
# 2. Without --quick: ctest -R TestMetal at -j2, about 10 minutes on ultra-base, 20 with the plugin
#    tests, in one gate-ctest.sh run, longest tests first (ctest's cost data; a tree with none gets
#    gate-cost.txt, the per-test seconds of a trunk gate). forces.py runs beside it, so its CPU phases
#    (system setup, Metal kernel compiles) overlap the ctest GPU work.
#    A failed statistical test (gate-ctest.sh's list, or a failure that says "This test is
#    stochastic") is rerun up to 3 times and passes if a rerun passes; the verdict line says on
#    which attempt. Any other failure fails the gate. Every listed test must have run.
# --quick is the R&D gate: screen a candidate only after it passes. The full gate is for a candidate
# that screened at 3% or more, and for the integrated build.
# The whole gate is one lease.sh --correctness hold with a 45 minute cap: gate.sh does its CPU-only setup
# (checks, the log dir, the ctest listing, the cost data), queues one ticket, then forces and ctest run
# inside the hold. Other correctness tickets at the head of the queue still join it, up to 3 members.
# Don't call it inside your own lease.sh. It
# refuses a tree whose src changed after build.sh. Logs go to <dir>/gate-<time>/. The last line is
# PASS or FAIL. --merge-path queues the gate's ticket in the merge-path class (lease.sh): only for a full
# gate of ultra-integrated or of a candidate the lead listed in ultra-tools/merge-queue.txt.
#   /bin/sh -c 'nohup /tmp/openmm-metal-bench/ultra-tools/gate.sh --quick /tmp/openmm-metal-bench/ultra-<lane> > /tmp/openmm-metal-bench/ultra-<lane>/gate.out 2>&1 < /dev/null &'
# GPUQ_PREFLIGHT=1 (gpuq submit sets it) runs every check, then exits 0 before queuing.
# usage: gate.sh [--quick | --merge-path] <dir>
set -eu
TOOLS=/tmp/openmm-metal-bench/ultra-tools
BASE=/tmp/openmm-metal-bench/ultra-base
# Override only for a gate run under foreign GPU load (tests run 2-3x slower).
GATE_CAP_SECONDS=${GATE_CAP_SECONDS:-2700}
export PATH=/tmp/openmm-metal-bench/env/bin:$PATH
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
unset PYTHONPATH
nice_value=$(ps -o nice= -p $$ | tr -d ' ')
[ -n "${GPUQ_PREFLIGHT:-}" ] || [ "$nice_value" = 0 ] || { echo "running at nice $nice_value, not 0: launch through /bin/sh -c 'nohup ...'" >&2; exit 2; }
quick=0
merge_path_flag=""
while :; do
    case "${1:-}" in
    --quick) quick=1; shift ;;
    --merge-path) merge_path_flag=--merge-path; shift ;;
    *) break ;;
    esac
done
[ $# -eq 1 ] || { echo "usage: gate.sh [--quick | --merge-path] <dir>" >&2; exit 2; }
dir="${1%/}"
dir="${dir%/venv}"
[ -x "$dir/venv/bin/python" ] && [ -f "$dir/build/CTestTestfile.cmake" ] || { echo "$dir has no venv or build; run build.sh" >&2; exit 2; }
[ -f "$dir/BUILT" ] || { echo "$dir/BUILT is missing: the last build.sh failed or never ran" >&2; exit 2; }
[ "$(sed -n 's/^src //p' "$dir/BUILT")" = "$("$TOOLS/srchash.sh" "$dir")" ] || { echo "$dir/src changed after build.sh; rebuild first" >&2; exit 2; }
[ -f "$BASE/forces.txt" ] || { echo "$BASE/forces.txt is missing" >&2; exit 2; }
/tmp/openmm-metal-bench/env/bin/python3 "$TOOLS/check-pin.py" "$dir"
lane="$(basename "$dir")"
if [ -z "${GATE_HELD:-}" ]; then
    # CPU-only setup, before the hold.
    tests=""
    if [ $quick = 0 ]; then
        tests="$(ctest --test-dir "$dir/build" -N -R TestMetal | sed -n 's/^ *Test *#[0-9]*: \([A-Za-z0-9_]*\)$/\1/p')"
        [ -n "$tests" ] || { echo "ctest lists no TestMetal tests in $dir/build" >&2; exit 2; }
    fi
    quick_flag=""
    [ $quick = 1 ] && quick_flag=--quick
    [ -z "${GPUQ_PREFLIGHT:-}" ] || { echo "preflight ok: gate.sh $dir"; exit 0; }
    out="$dir/gate-$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir -p "$out"
    if [ $quick = 0 ]; then
        echo "$tests" > "$out/tests.txt"
        cp "$out/tests.txt" "$out/tests-1.txt"
        cost="$dir/build/Testing/Temporary/CTestCostData.txt"
        [ -s "$cost" ] || { mkdir -p "$(dirname "$cost")" && { cat "$TOOLS/gate-cost.txt"; echo ---; } > "$cost"; }
    fi
    export GATE_HELD=1 GATE_OUT="$out"
    exec "$TOOLS/lease.sh" --correctness $merge_path_flag --cap $GATE_CAP_SECONDS "$lane" "gate.sh${quick_flag:+ $quick_flag} $dir" "$0" $quick_flag "$dir"
fi
out="${GATE_OUT:?gate.sh sets GATE_OUT before its hold}"
echo "gate$([ $quick = 1 ] && echo " --quick") $dir, $(sed -n 's/^commit //p' "$dir/BUILT"), logs in $out"
failed=0

"$TOOLS/lease.sh" --correctness "$lane" "gate.sh forces $dir" "$dir/venv/bin/python" "$TOOLS/forces.py" "$BASE/benchmarks" "$out/forces.txt" "$BASE/forces.txt" \
    > "$out/forces-verdict.txt" 2>&1 &
forces_pid=$!
if [ $quick = 0 ]; then
    "$TOOLS/lease.sh" --correctness "$lane" "gate.sh ctest $dir" "$TOOLS/gate-ctest.sh" "$dir" "$out" 1 || true
fi
wait $forces_pid || failed=1
cat "$out/forces-verdict.txt"
if [ $quick = 0 ]; then
    count="$(wc -l < "$out/tests.txt" | tr -d ' ')"
    grep -v '^done part' "$out/verdict-1.txt" 2>/dev/null || true
    grep -q '^FAIL' "$out/verdict-1.txt" 2>/dev/null && failed=1
    grep -qx "done part 1" "$out/verdict-1.txt" 2>/dev/null || { echo "FAIL ctest did not finish, see $out/ctest-1.txt"; failed=1; }
    echo "ctest: $count tests, $(grep -cE '\*\*\*(Failed|Timeout|Exception)' "$out/ctest-1.txt" 2>/dev/null || true) failed in the -j2 run"
fi

[ $failed = 0 ] && echo PASS || echo FAIL
[ $failed = 0 ]

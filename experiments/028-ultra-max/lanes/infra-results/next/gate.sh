#!/bin/sh
# Runs on the M3 Ultra at nice 0: the correctness gate for a tree that build.sh built.
# 1. forces.py, Metal single and mixed against Reference on gbsa, rf, pme, apoa1rf, apoa1pme and
#    apoa1ljpme, compared with ultra-base/forces.txt (see forces.py for the rule). A minute or two.
# 2. Without --quick: ctest -R TestMetal at -j2, about 10 minutes on ultra-base, 20 with the plugin
#    tests. The tests are split round-robin into parts of at most 30, each run by gate-ctest.sh.
#    A failed statistical test (gate-ctest.sh's list, or a failure that says "This test is
#    stochastic") is rerun up to 3 times and passes if a rerun passes; the verdict line says on
#    which attempt. Any other failure fails the gate. Every listed test must have run.
# --quick is the R&D gate: screen a candidate only after it passes. The full gate is for a candidate
# that screened at 3% or more, and for the integrated build.
# The whole gate is one lease.sh --correctness hold with a 45 minute cap: gate.sh queues one ticket,
# then forces and every ctest part run inside the hold. Other correctness tickets at the head of the
# queue still join it, up to 3 members. Don't call it inside your own lease.sh. It
# refuses a tree whose src changed after build.sh. Logs go to <dir>/gate-<time>/. The last line is
# PASS or FAIL.
#   /bin/sh -c 'nohup /tmp/openmm-metal-bench/ultra-tools/gate.sh --quick /tmp/openmm-metal-bench/ultra-<lane> > /tmp/openmm-metal-bench/ultra-<lane>/gate.out 2>&1 < /dev/null &'
# usage: gate.sh [--quick] <dir>
set -eu
TOOLS=/tmp/openmm-metal-bench/ultra-tools
BASE=/tmp/openmm-metal-bench/ultra-base
PART_TESTS=30
GATE_CAP_SECONDS=2700
export PATH=/tmp/openmm-metal-bench/env/bin:$PATH
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
unset PYTHONPATH
nice_value=$(ps -o nice= -p $$ | tr -d ' ')
[ "$nice_value" = 0 ] || { echo "running at nice $nice_value, not 0: launch through /bin/sh -c 'nohup ...'" >&2; exit 2; }
quick=0
[ "${1:-}" = --quick ] && { quick=1; shift; }
[ $# -eq 1 ] || { echo "usage: gate.sh [--quick] <dir>" >&2; exit 2; }
dir="${1%/}"
dir="${dir%/venv}"
[ -x "$dir/venv/bin/python" ] && [ -f "$dir/build/CTestTestfile.cmake" ] || { echo "$dir has no venv or build; run build.sh" >&2; exit 2; }
[ -f "$dir/BUILT" ] || { echo "$dir/BUILT is missing: the last build.sh failed or never ran" >&2; exit 2; }
[ "$(sed -n 's/^src //p' "$dir/BUILT")" = "$("$TOOLS/srchash.sh" "$dir")" ] || { echo "$dir/src changed after build.sh; rebuild first" >&2; exit 2; }
[ -f "$BASE/forces.txt" ] || { echo "$BASE/forces.txt is missing" >&2; exit 2; }
lane="$(basename "$dir")"
if [ -z "${GATE_HELD:-}" ]; then
    quick_flag=""
    [ $quick = 1 ] && quick_flag=--quick
    export GATE_HELD=1
    exec "$TOOLS/lease.sh" --correctness --cap $GATE_CAP_SECONDS "$lane" "gate.sh${quick_flag:+ $quick_flag} $dir" "$0" $quick_flag "$dir"
fi
out="$dir/gate-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$out"
echo "gate$([ $quick = 1 ] && echo " --quick") $dir, $(sed -n 's/^commit //p' "$dir/BUILT"), logs in $out"
failed=0

"$TOOLS/lease.sh" --correctness "$lane" "gate.sh forces $dir" "$dir/venv/bin/python" "$TOOLS/forces.py" "$BASE/benchmarks" "$out/forces.txt" "$BASE/forces.txt" \
    > "$out/forces-verdict.txt" 2>&1 || failed=1
cat "$out/forces-verdict.txt"

if [ $quick = 0 ]; then
    ctest --test-dir "$dir/build" -N -R TestMetal | sed -n 's/^ *Test *#[0-9]*: \([A-Za-z0-9_]*\)$/\1/p' > "$out/tests.txt"
    count="$(wc -l < "$out/tests.txt" | tr -d ' ')"
    parts=$(( (count + PART_TESTS - 1) / PART_TESTS ))
    [ "$count" -gt 0 ] || { echo "ctest lists no TestMetal tests in $dir/build"; failed=1; }
    [ "$count" -gt 0 ] && awk -v parts=$parts -v out="$out" '{ print > (out "/tests-" ((NR - 1) % parts + 1) ".txt") }' "$out/tests.txt"
    part=1
    while [ $part -le $parts ]; do
        "$TOOLS/lease.sh" --correctness "$lane" "gate.sh ctest part $part/$parts $dir" "$TOOLS/gate-ctest.sh" "$dir" "$out" $part || true
        grep -v '^done part' "$out/verdict-$part.txt" 2>/dev/null || true
        grep -q '^FAIL' "$out/verdict-$part.txt" 2>/dev/null && failed=1
        grep -qx "done part $part" "$out/verdict-$part.txt" 2>/dev/null || { echo "FAIL ctest part $part did not finish, see $out/ctest-$part.txt"; failed=1; }
        part=$((part+1))
    done
    echo "ctest: $count tests in $parts parts, $(cat "$out"/ctest-*.txt 2>/dev/null | grep -cE '\*\*\*(Failed|Timeout|Exception)' || true) failed in the -j2 runs"
fi

[ $failed = 0 ] && echo PASS || echo FAIL
[ $failed = 0 ]

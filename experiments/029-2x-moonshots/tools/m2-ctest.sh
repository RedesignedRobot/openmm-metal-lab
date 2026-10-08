#!/bin/sh
# Runs on the M2 through locked.py on job.lock, so no sync, build or check overlaps it: the full
# ctest -R TestMetal suite on one m2build.sh tree (default base), split into parts of at most 30 like
# gate.sh, each part in its own m2-lease.sh correctness ticket and run by gate-ctest.sh (same -j2,
# stochastic-rerun rule and verdict lines as the Ultra gate). Output goes to
# checks/<UTC time>-ctest-<commit>/; the last line is PASS or FAIL.
#   /opt/homebrew/bin/python3 tools/locked.py job.lock tools/m2-ctest.sh [tree]
set -eu
ROOT=$HOME/lab/ultra-m2.noindex
TOOLS=$ROOT/tools
PART_TESTS=30
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
unset PYTHONPATH OPENMM_PLUGIN_DIR DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH DYLD_INSERT_LIBRARIES
nice_value=$(ps -o nice= -p $$ | tr -d ' ')
[ "$nice_value" = 0 ] || { echo "running at nice $nice_value, not 0" >&2; exit 2; }
dir="${1:-$ROOT/base}"
[ -f "$dir/BUILT" ] && [ -f "$dir/build/CTestTestfile.cmake" ] || { echo "$dir has no BUILT or build" >&2; exit 2; }
commit="$(sed -n 's/^commit //p' "$dir/BUILT")"
out="$ROOT/checks/$(date -u +%Y%m%dT%H%M%SZ)-ctest-$(echo "$commit" | cut -c1-9)"
mkdir -p "$out"
echo "M2 TestMetal suite on $dir at $commit, logs in $out"
start=$(date +%s)
ctest --test-dir "$dir/build" -N -R TestMetal | sed -n 's/^ *Test *#[0-9]*: \([A-Za-z0-9_]*\)$/\1/p' > "$out/tests.txt"
count="$(wc -l < "$out/tests.txt" | tr -d ' ')"
[ "$count" -gt 0 ] || { echo "ctest lists no TestMetal tests in $dir/build"; echo FAIL; exit 1; }
parts=$(( (count + PART_TESTS - 1) / PART_TESTS ))
awk -v parts=$parts -v out="$out" '{ print > (out "/tests-" ((NR - 1) % parts + 1) ".txt") }' "$out/tests.txt"
failed=0
part=1
while [ $part -le $parts ]; do
    "$TOOLS/m2-lease.sh" --correctness --cap 2700 ultra-m2 "M2 ctest part $part/$parts" "$TOOLS/gate-ctest.sh" "$dir" "$out" $part || true
    grep -v '^done part' "$out/verdict-$part.txt" 2>/dev/null || true
    grep -q '^FAIL' "$out/verdict-$part.txt" 2>/dev/null && failed=1
    grep -qx "done part $part" "$out/verdict-$part.txt" 2>/dev/null || { echo "FAIL ctest part $part did not finish, see $out/ctest-$part.txt"; failed=1; }
    part=$((part+1))
done
echo "ctest: $count tests in $parts parts, $(cat "$out"/ctest-*.txt | grep -cE '\*\*\*(Failed|Timeout|Exception)' || true) failed in the -j2 runs, $(( $(date +%s) - start )) s"
[ $failed = 0 ] && echo PASS || echo FAIL
[ $failed = 0 ]

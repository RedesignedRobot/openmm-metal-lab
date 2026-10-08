#!/bin/sh
# covers: m2summary.py   (install.sh runs this test when one of these changes)
# m2summary.py's footprint verdict on made-up M2 checks, no M2 needed. The candidate is judged against every
# base round of the same base build in the check and its sibling checks.
# - apoa1pme single: r3-interp's real rounds (2026-09-28), base 296.1 and 296.1 MB, candidate 322.3 and 314.7:
#   GROWTH. A sibling with another base build and 330 MB rounds must not join the pool, or the flag would drop.
# - apoa1pme mixed: an A/A shape from the real base history. This check's base sits on the 296 MB floor and
#   the candidate draws two excursions (312.4, 314.2); the siblings hold the base's other excursions. The
#   pre-pool rule flagged this at +17 MB; the pooled rule must not.
# - apoa1ljpme single: overlapping rounds, no flag. pme mixed: +1 MB, under the floor.
# - gbsa single: one candidate round, counts as missing. amber20-dhfr mixed: no candidate footprint, missing.
# - p1, another base build: the candidate runs 10% slower on the M2 with forces and footprint clean. The verdict
#   is PASS and the slow row shows only on the speed line, because M2 speed is reported, not gated (R3-5).
# usage: tests/m2summary.sh [scratch dir]
set -u
TOOLS=$(cd "$(dirname "$0")/.." && pwd)
PY=/tmp/openmm-metal-bench/env/bin/python3
S=${1:-/tmp/openmm-metal-bench/ultra-r3-tools/m2summary-test}
rm -rf "$S"
mkdir -p "$S/checks"
fail=0
ok() { echo "  PASS $*"; }
bad() { echo "  FAIL $*"; fail=1; }

# Per check: its base line, then rows of test precision -> (base rounds, candidate rounds or None) in MB.
$PY - "$S/checks" <<'EOF'
import json, os, sys
root = sys.argv[1]
BASE = "base /m2/base: commit 8ae6cf17bef6a6084f4f0d12fa6aa5705dd73374 src b01853a1 built 2026-09-27T06:37:04Z"
OTHER = "base /m2/base: commit 8ae6cf17bef6a6084f4f0d12fa6aa5705dd73374 src b01853a1 built 2026-09-30T01:00:00Z"
checks = {
    "c1": (BASE, {("apoa1pme", "single"): ((296.1, 296.1), (322.3, 314.7)),
                  ("apoa1pme", "mixed"): ((296.1, 296.2), (312.4, 314.2)),
                  ("apoa1ljpme", "single"): ((311.6, 315.3), (320.8, 300.0)),
                  ("pme", "mixed"): ((127.2, 128.4), (128.5, 129.0)),
                  ("gbsa", "single"): ((101.0, 101.2), (109.0,)),
                  ("amber20-dhfr", "mixed"): ((147.0, 147.2), None)}),
    "h1": (BASE, {("apoa1pme", "mixed"): ((296.1, 313.4), None)}),
    "h2": (BASE, {("apoa1pme", "mixed"): ((296.0, 315.3), None)}),
    "h3": (BASE, {("apoa1pme", "mixed"): ((312.5, 316.1), None)}),
    "h4": (BASE, {("apoa1pme", "mixed"): ((299.6, 320.7), None)}),
    "h5": (BASE, {("apoa1pme", "mixed"): ((296.2, 311.3), None)}),
    "o1": (OTHER, {("apoa1pme", "single"): ((330.0, 330.0), None)}),
    "p1": (OTHER, {("pme", "mixed"): ((127.2, 128.4), (128.5, 129.0))}),
}
CAND_SPEED = {"p1": 90.0}
for name, (base_line, rows) in checks.items():
    out = os.path.join(root, name)
    os.makedirs(out)
    for (test, precision), arms in rows.items():
        for who, values in zip(("base", "cand-x"), arms):
            speed = CAND_SPEED.get(name, 100.0) if who == "cand-x" else 100.0
            for r, value in enumerate(values or (), 1):
                stem = f"{out}/{who}-{precision}-{test}-round{r}"
                json.dump({"benchmarks": [{"test": test, "ns_per_day": speed}]}, open(stem + ".json", "w"))
                open(stem + ".time", "w").write(f"  {int(value * 1048576)}  peak memory footprint\n"
                                                f"  {int(value * 1048576)}  maximum resident set size\n")
            if who == "cand-x" and values is None and name == "c1":
                for r in (1, 2):
                    json.dump({"benchmarks": [{"test": test, "ns_per_day": 100.0}]},
                              open(f"{out}/{who}-{precision}-{test}-round{r}.json", "w"))
    open(f"{out}/configs.txt", "w").write(base_line + "\ncand-x Metal commit 4c26efa9b523000000000000000000000000000\n")
    open(f"{out}/gate-cand-x.txt", "w").write("PASS\n")
EOF

$PY $TOOLS/m2summary.py $S/checks/c1 > $S/summary.txt 2>&1 || bad "m2summary.py exited $?: $(cat $S/summary.txt)"
verdict=$(grep '^verdict cand-x' $S/summary.txt)
row() { grep -E "^$1 +$2 " $S/summary.txt; }
grep -q "against the 6 checks of this base build" $S/summary.txt && ok "pool: 6 checks of the same build, the other build left out" \
    || bad "pool line: $(grep GROWTH $S/summary.txt)"
row apoa1pme single | grep -q "GROWTH" && ok "apoa1pme single +22 MB flagged: $(row apoa1pme single | tr -s ' ')" \
    || bad "apoa1pme single: $(row apoa1pme single)"
row apoa1pme mixed | grep -q "GROWTH" && bad "apoa1pme mixed A/A excursions flagged: $(row apoa1pme mixed)" \
    || ok "apoa1pme mixed A/A excursions (+17 MB against this check's base): no flag"
row apoa1ljpme single | grep -q "GROWTH" && bad "apoa1ljpme single flagged with overlapping rounds" \
    || ok "apoa1ljpme single, overlapping rounds: no flag"
row pme mixed | grep -q "GROWTH" && bad "pme mixed flagged at +1 MB" || ok "pme mixed, +1 MB: no flag"
case "$verdict" in
*"FLAGGED"*"footprint growth: apoa1pme single +22 MB (+7.6%) over 2 base rounds;"*"missing: "*"gbsa single footprint needs 2 rounds"*"amber20-dhfr mixed footprint"*)
    ok "verdict: $verdict" ;;
*) bad "verdict: $verdict" ;;
esac

$PY $TOOLS/m2summary.py $S/checks/p1 > $S/slow.txt 2>&1 || bad "m2summary.py exited $?: $(cat $S/slow.txt)"
verdict=$(grep '^verdict cand-x' $S/slow.txt)
speed=$(grep '^speed cand-x' $S/slow.txt)
grep -E "^pme +mixed " $S/slow.txt | grep -q SLOWER && ok "pme mixed at 0.900 still marked SLOWER in the table" \
    || bad "pme mixed row: $(grep -E '^pme +mixed ' $S/slow.txt)"
case "$verdict" in
*" PASS: gate PASS; footprint growth: none; missing: none") ok "10% slower on the M2, verdict: $verdict" ;;
*) bad "slow candidate verdict: $verdict" ;;
esac
case "$speed" in
*"not gated"*"slower: pme mixed 0.900") ok "speed line: $speed" ;;
*) bad "speed line: $speed" ;;
esac

rm -rf "$S"
echo "result: $([ $fail = 0 ] && echo PASS || echo FAIL)"
exit $fail

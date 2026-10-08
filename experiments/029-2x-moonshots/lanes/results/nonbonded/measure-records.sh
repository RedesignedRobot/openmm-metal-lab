#!/bin/sh
set -eu
root=/tmp/openmm-metal-bench
lane=$root/ultra-m29-nonbonded
records=$root/ultra-m29-nonbonded-records
trap 'result=$?; if [ "$result" -ne 0 ]; then printf "FAILED exit=%s; inspect measure-records.out\n" "$result" > "$lane/records-screen.verdict"; fi' EXIT
[ -f "$root/READY" ] && [ -f "$records/BUILT" ]
[ -f "$lane/blocks-screen-amber20-cellulose/ratios.txt" ]
"$root/ultra-tools/gate.sh" --quick "$records"
"$root/ultra-tools/lease.sh" --correctness ultra-m29-nonbonded 'private force records one-step smoke' "$lane/smoke-arms.sh" "$records"
for test in amber20-cellulose amber20-stmv apoa1rf; do
    "$lane/record-screen.sh" "$test"
done
printf '%s\n' 'SCREEN_COMPLETE private force records quick gate and cellulose/stmv/apoa1rf single; ratios need review' > "$lane/records-screen.verdict"

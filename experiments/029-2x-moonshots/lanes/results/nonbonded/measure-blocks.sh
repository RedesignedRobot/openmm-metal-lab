#!/bin/sh
set -eu
root=/tmp/openmm-metal-bench
lane=$root/ultra-m29-nonbonded
blocks=$root/ultra-m29-nonbonded-blocks
trap 'result=$?; if [ "$result" -ne 0 ]; then printf "FAILED exit=%s; inspect measure-blocks.out\n" "$result" > "$lane/blocks-screen.verdict"; fi' EXIT
[ -f "$root/READY" ] && [ -f "$blocks/BUILT" ] && [ ! -f "$blocks/NEEDS_REBUILD" ]
"$root/ultra-tools/gate.sh" --quick "$blocks"
"$root/ultra-tools/lease.sh" --correctness ultra-m29-nonbonded 'force-block one-step smoke' "$lane/smoke-arms.sh" "$blocks"
for test in amber20-cellulose amber20-stmv apoa1rf; do
    "$lane/step-a-screen.sh" "$test"
done
printf '%s\n' 'SCREEN_COMPLETE force-block quick gate and cellulose/stmv/apoa1rf single; ratios need review' > "$lane/blocks-screen.verdict"

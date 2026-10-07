#!/bin/sh
set -eu
root=/tmp/openmm-metal-bench
lane=$root/ultra-m29-nonbonded
selected=$root/ultra-m29-nonbonded-selected
trap 'result=$?; if [ "$result" -ne 0 ]; then printf "FAILED exit=%s; inspect confirm-selected.out\n" "$result" > "$lane/maxbits-confirm.verdict"; fi' EXIT
[ -f "$selected/BUILT" ]
"$root/ultra-tools/gate.sh" --quick "$selected"
"$lane/confirm.sh" "$selected" maxbits-confirm

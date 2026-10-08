#!/bin/sh
set -u
root=/tmp/openmm-metal-bench
lane=$root/ultra-m29-nonbonded
candidate=$root/ultra-m29-nonbonded-final
while [ ! -f "$candidate/BUILT" ]; do sleep 30; done
"$root/ultra-tools/gate.sh" --quick "$candidate"
quick=$?
"$root/ultra-tools/lease.sh" --correctness ultra-m29-nonbonded 'final MAX_BITS md100, detforces and captured-state diagnosis' "$lane/validate-final.sh"
validation=$?
printf 'quick_gate_exit=%s validation_exit=%s; see final/validation.verdict\n' "$quick" "$validation" > "$lane/final-validation.verdict"
[ "$quick" -eq 0 ] && [ "$validation" -eq 0 ]

#!/bin/sh
set -u
root=/tmp/openmm-metal-bench
lane=$root/ultra-m29-nonbonded
selected=$root/ultra-m29-nonbonded-selected
bench=$root/ultra-base/benchmarks
out=$lane/selected-pme-md100-diagnostic
"$selected/venv/bin/python" "$lane/capture-md100.py" "$out" --md 100 "$bench" "$selected/forces-md100.txt" "$root/ultra-base/forces-md100.txt"
md_status=$?
"$selected/venv/bin/python" "$root/ultra-tools/detforces.py" "$bench" "$selected/detforces.txt"
det_status=$?
"$selected/venv/bin/python" "$lane/pme-force-diagnostic.py" evaluate "$out" candidate
"$root/ultra-int028/venv/bin/python" "$lane/pme-force-diagnostic.py" evaluate "$out" int028
"$selected/venv/bin/python" "$lane/pme-force-diagnostic.py" evaluate "$out" reference
"$root/env/bin/python" "$lane/summarize-pme-diagnostic.py" "$out" > "$out/comparison.json"
"$selected/venv/bin/python" "$lane/pme-cutoff-diagnostic.py" "$out" > "$out/cutoff-diagnostic.out"
printf 'md100_exit=%s detforces_exit=%s; pme state captured for diagnosis\n' "$md_status" "$det_status" > "$selected/validation.verdict"
[ "$md_status" -eq 0 ] && [ "$det_status" -eq 0 ]

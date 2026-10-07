#!/bin/sh
set -u
root=/tmp/openmm-metal-bench
lane=$root/ultra-m29-nonbonded
bench=$root/ultra-base/benchmarks
"$root/ultra-int028/venv/bin/python" "$root/ultra-tools/forces.py" --md 100 "$bench" "$lane/int028-forces-md100.txt" "$root/ultra-base/forces-md100.txt"
base_status=$?
"$lane/venv/bin/python" "$root/ultra-tools/detforces.py" "$bench" "$lane/detforces.txt"
det_status=$?
spread_status=0
for precision in single mixed; do
    "$lane/venv/bin/python" "$lane/force-spread.py" "$bench" "$lane/default-spread-$precision" apoa1rf "$precision" || spread_status=1
    "$lane/venv/bin/python" "$lane/force-spread.py" "$bench" "$lane/deterministic-spread-$precision" apoa1rf "$precision" --deterministic || spread_status=1
done
printf 'int028_md100_exit=%s candidate_detforces_exit=%s fresh_process_spread_exit=%s\n' "$base_status" "$det_status" "$spread_status" > "$lane/md-baseline.verdict"

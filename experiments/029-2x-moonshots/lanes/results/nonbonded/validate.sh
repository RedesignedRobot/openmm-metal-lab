#!/bin/sh
set -eu
root=/tmp/openmm-metal-bench
[ "$#" -eq 1 ] || { echo 'usage: validate.sh CANDIDATE_DIR'; exit 2; }
lane=$1
bench=$root/ultra-base/benchmarks
python=$lane/venv/bin/python
"$python" "$root/ultra-tools/forces.py" --md 100 "$bench" "$lane/forces-md100.txt" "$root/ultra-base/forces-md100.txt"
"$python" "$root/ultra-tools/detforces.py" "$bench" "$lane/detforces.txt"
for precision in single mixed; do
    "$python" "$root/ultra-m29-nonbonded/force-spread.py" "$bench" "$lane/default-spread-$precision" apoa1rf "$precision"
    "$python" "$root/ultra-m29-nonbonded/force-spread.py" "$bench" "$lane/deterministic-spread-$precision" apoa1rf "$precision" --deterministic
done
printf '%s\n' 'PASS md100, detforces.py, and fresh-process deterministic forces' > "$lane/validation.verdict"

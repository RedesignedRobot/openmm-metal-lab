#!/bin/sh
set -eu
root=/tmp/openmm-metal-bench
lane=$root/ultra-m29-nonbonded
[ "$#" -eq 2 ] || { echo 'usage: confirm.sh candidate-dir output-tag'; exit 2; }
candidate=$1
tag=$2
[ -f "$root/READY" ] && [ -f "$candidate/BUILT" ]
base=$root/ultra-int028/venv/bin/python
mine=$candidate/venv/bin/python
for test in gbsa rf pme apoa1rf apoa1pme apoa1ljpme amber20-dhfr amber20-cellulose; do
    "$root/ultra-tools/ab.sh" "$lane/$tag-$test" 3 30 "$test" \
        base-s=$base:Metal:single cand-s=$mine:Metal:single cl-s=$base:OpenCL:single \
        base-m=$base:Metal:mixed cand-m=$mine:Metal:mixed
done
"$root/ultra-tools/ab.sh" "$lane/$tag-amber20-stmv-single" 3 30 amber20-stmv \
    base-s=$base:Metal:single cand-s=$mine:Metal:single cl-s=$base:OpenCL:single
"$root/ultra-tools/ab.sh" "$lane/$tag-amber20-stmv-mixed" 3 30 amber20-stmv \
    base-m=$base:Metal:mixed cand-m=$mine:Metal:mixed
"$root/env/bin/python" "$lane/ratio-table.py" 3 "$lane/$tag-"* > "$lane/$tag-table.md"
printf '%s\n' 'CONFIRMATION_COMPLETE all nine single and mixed; inspect ratios and build-overlap flags' > "$lane/$tag.verdict"

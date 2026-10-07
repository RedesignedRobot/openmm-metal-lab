#!/bin/sh
set -eu
root=/tmp/openmm-metal-bench
lane=$root/ultra-m29-nonbonded
if [ "${1:-}" != --held ]; then
 exec "$root/ultra-tools/lease.sh" ultra-m29-nonbonded 'replace build-overlapped amber20-dhfr confirmation round 1, all five arms' "$0" --held
fi
export AB_OUT=$lane/maxbits-confirm-amber20-dhfr AB_ROUND=1 AB_TEST=amber20-dhfr AB_SECONDS=30
mkdir -p "$AB_OUT/replaced"
for label in base-s cand-s cl-s base-m cand-m; do
 mv "$AB_OUT/$label-amber20-dhfr-round1.json" "$AB_OUT/replaced/"
done
printf '%s rerun round 1 amber20-dhfr: a build overlapped the original paired round\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$AB_OUT/loads.txt"
base=$root/ultra-int028/venv/bin/python
mine=$root/ultra-m29-nonbonded-selected/venv/bin/python
cd "$root/ultra-base/benchmarks"
"$root/ultra-tools/ab-test.sh" base-s=$base:Metal:single cand-s=$mine:Metal:single cl-s=$base:OpenCL:single base-m=$base:Metal:mixed cand-m=$mine:Metal:mixed
"$root/env/bin/python" "$root/ultra-tools/summarize.py" "$AB_OUT" > "$AB_OUT/ratios.txt"
printf 'COMPLETE replaced all five arms in contaminated amber20-dhfr round 1; inspect ratios.txt\n' > "$lane/amber20-dhfr-repair.verdict"

#!/bin/sh
set -eu
root=/tmp/openmm-metal-bench
lane=$root/ultra-m29-nonbonded
verdict=$lane/ready-waiter.verdict
trap 'result=$?; if [ "$result" -ne 0 ]; then printf "FAILED exit=%s; inspect ready-waiter.out\n" "$result" > "$verdict"; fi' EXIT
while [ ! -f "$root/READY" ] || [ ! -f "$lane/BUILT" ]; do
    sleep 30
done
"$root/ultra-tools/lease.sh" --correctness ultra-m29-nonbonded 'one-step smoke for all MAX_BITS timing arms' "$lane/smoke-arms.sh" "$lane"
"$lane/measure-maxbits.sh"
printf '%s\n' 'SCREEN_COMPLETE MAX_BITS quick gate and all nine single/mixed/OpenCL arms; ratios need review' > "$verdict"

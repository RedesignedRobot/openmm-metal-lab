#!/bin/sh
set -eu
root=/tmp/openmm-metal-bench/ultra-m29-resident
proto=/tmp/openmm-metal-bench/ultra-m29-resident-prototype
tools=/tmp/openmm-metal-bench/ultra-tools
base=/tmp/openmm-metal-bench/ultra-int028
export PATH=/tmp/openmm-metal-bench/env/bin:$PATH
phase=prototype-correctness
trap 'rc=$?; if [ "$rc" -ne 0 ]; then printf "FAILED phase=%s exit=%s\n" "$phase" "$rc" > "$root/ready-run.verdict"; fi' EXIT
[ -f /tmp/openmm-metal-bench/READY ]
[ -f "$root/kstep-screen.verdict" ]
printf '%s\n' RUNNING_PROTOTYPE_CORRECTNESS_BUNDLE > "$root/ready-run.verdict"
"$tools/lease.sh" --correctness ultra-m29-resident "prototype smoke, batching, md100 and detforces" "$root/prototype-checks.sh" > "$root/prototype-checks.out" 2>&1
for group in small control; do
    if [ "$group" = small ]; then tests=gbsa,rf; else tests=pme,amber20-dhfr; fi
    phase=prototype-screen-$group
    printf '%s\n' "RUNNING_$phase" > "$root/ready-run.verdict"
    "$tools/ab.sh" "$root/resident-screen-$group" 2 15 "$tests" \
        base-s="$base/venv/bin/python:Metal:single" \
        resident-s="$proto/venv/bin/python:Metal:single" \
        kstep-s="$root/venv/bin/python:Metal:single" \
        base-m="$base/venv/bin/python:Metal:mixed" \
        resident-m="$proto/venv/bin/python:Metal:mixed" \
        kstep-m="$root/venv/bin/python:Metal:mixed" \
        opencl="$base/venv/bin/python:OpenCL:single" > "$root/resident-screen-$group.out" 2>&1
    "$proto/venv/bin/python" "$tools/summarize.py" "$root/resident-screen-$group" resident-s/base-s resident-m/base-m resident-s/opencl resident-m/opencl resident-s/kstep-s resident-m/kstep-m kstep-s/base-s kstep-m/base-m > "$root/resident-screen-$group-summary.txt"
done
printf '%s\n' ULTRA_SCREENS_COMPLETE_M2_OWED > "$root/ready-run.verdict"

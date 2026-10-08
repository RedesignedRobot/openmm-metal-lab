#!/bin/sh
set -eu
root=/tmp/openmm-metal-bench/ultra-m29-resident
proto=/tmp/openmm-metal-bench/ultra-m29-resident-prototype
tools=/tmp/openmm-metal-bench/ultra-tools
base=/tmp/openmm-metal-bench/ultra-int028
bench=/tmp/openmm-metal-bench/ultra-base/benchmarks
export PATH=/tmp/openmm-metal-bench/env/bin:$PATH
phase=waiting-ready
trap 'rc=$?; if [ "$rc" -ne 0 ]; then printf "FAILED phase=%s exit=%s\n" "$phase" "$rc" > "$root/ready-run.verdict"; fi' EXIT
printf '%s\n' WAITING_READY > "$root/ready-run.verdict"
while [ ! -f /tmp/openmm-metal-bench/READY ]; do sleep 30; done
phase=checking-builds
[ -f "$root/BUILT" ]
[ -f "$proto/BUILT" ]
phase=kstep-quick-gate
"$tools/gate.sh" --quick "$root" > "$root/gate-kstep.out" 2>&1
phase=kstep-smoke
"$tools/lease.sh" --correctness ultra-m29-resident "one-step screen arms" "$root/smoke-kstep.sh" > "$root/smoke-kstep.out" 2>&1
phase=kstep-screen
"$root/screen-kstep.sh" > "$root/screen-kstep.out" 2>&1
printf '%s\n' KSTEP_ULTRA_SCREEN_COMPLETE > "$root/kstep-screen.verdict"
phase=prototype-quick-gate
"$tools/gate.sh" --quick "$proto" > "$root/gate-prototype.out" 2>&1
phase=prototype-smoke
for precision in single mixed; do
    "$tools/lease.sh" --correctness ultra-m29-resident "prototype one-step $precision" \
        "$proto/venv/bin/python" "$root/smoke.py" "$bench" Metal "$precision" > "$root/smoke-prototype-$precision.out" 2>&1
done
phase=prototype-command-batching-test
"$tools/lease.sh" --correctness ultra-m29-resident "command batching regression" \
    ctest --test-dir "$proto/build" -R '^TestMetalCommandBatchingSingle$' --output-on-failure > "$root/command-batching.out" 2>&1
phase=prototype-md100
"$tools/lease.sh" --correctness ultra-m29-resident "resident md100 forces" \
    "$proto/venv/bin/python" "$tools/forces.py" --md 100 "$bench" "$root/forces-md100.txt" /tmp/openmm-metal-bench/ultra-base/forces-md100.txt > "$root/forces-md100.out" 2>&1
phase=prototype-detforces
"$tools/lease.sh" --correctness ultra-m29-resident "resident deterministic forces" \
    "$proto/venv/bin/python" "$tools/detforces.py" "$bench" "$root/detforces.txt" > "$root/detforces.out" 2>&1
for group in small control; do
    if [ "$group" = small ]; then tests=gbsa,rf; else tests=pme,amber20-dhfr; fi
    phase=prototype-screen-$group
    "$tools/ab.sh" "$root/resident-screen-$group" 2 15 "$tests" \
        base-s="$base/venv/bin/python:Metal:single" \
        resident-s="$proto/venv/bin/python:Metal:single" \
        kstep-s="$root/venv/bin/python:Metal:single" \
        base-m="$base/venv/bin/python:Metal:mixed" \
        resident-m="$proto/venv/bin/python:Metal:mixed" \
        kstep-m="$root/venv/bin/python:Metal:mixed" \
        opencl="$base/venv/bin/python:OpenCL:single" > "$root/resident-screen-$group.out" 2>&1
    "$proto/venv/bin/python" "$tools/summarize.py" "$root/resident-screen-$group" resident-s/base-s resident-m/base-m resident-s/opencl resident-m/opencl resident-s/kstep-s resident-m/kstep-m > "$root/resident-screen-$group-summary.txt"
done
phase=ultra-screen-complete
printf '%s\n' ULTRA_SCREENS_COMPLETE_M2_OWED > "$root/ready-run.verdict"

#!/bin/sh
set -eu
D=/tmp/openmm-metal-bench/ultra-m29-mixed
C=/tmp/openmm-metal-bench/ultra-m29-mixed-census
M=/tmp/openmm-metal-bench/ultra-m29-mixed-minimizer
T=/tmp/openmm-metal-bench/ultra-tools
B=/tmp/openmm-metal-bench/ultra-int028
export PATH=/tmp/openmm-metal-bench/env/bin:$PATH
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
unset PYTHONPATH OPENMM_PLUGIN_DIR
trap 'rc=$?; if [ "$rc" -ne 0 ]; then echo "FAILED stage=$stage rc=$rc" > "$D/verdict.txt"; fi' EXIT
stage=ready
while [ ! -f /tmp/openmm-metal-bench/READY ] || [ ! -f "$D/BUILT" ] || [ ! -f "$C/BUILT" ]; do sleep 60; done
stage=census
"$T/lease.sh" m29-mixed "028 mixed kernel census" "$D/census-run.sh" > "$D/census.out" 2>&1
stage=targeted
"$T/lease.sh" --correctness m29-mixed "SHAKE SETTLE mixed integration and COM tests" "$D/targeted.sh" > "$D/targeted.out" 2>&1
stage=quick
"$T/gate.sh" --quick "$D" > "$D/gate.out" 2>&1
stage=screen-small
"$T/ab.sh" "$D/screen-small" 2 15 gbsa,rf,pme \
    baseS="$B/venv/bin/python:Metal:single" baseM="$B/venv/bin/python:Metal:mixed" \
    mineS="$D/venv/bin/python:Metal:single" mineM="$D/venv/bin/python:Metal:mixed" \
    opencl="$B/venv/bin/python:OpenCL:single" > "$D/screen-small.out" 2>&1
stage=screen-large
"$T/ab.sh" "$D/screen-large" 2 15 amber20-dhfr,apoa1pme \
    baseS="$B/venv/bin/python:Metal:single" baseM="$B/venv/bin/python:Metal:mixed" \
    mineS="$D/venv/bin/python:Metal:single" mineM="$D/venv/bin/python:Metal:mixed" \
    opencl="$B/venv/bin/python:OpenCL:single" > "$D/screen-large.out" 2>&1
stage=done
echo 'SCREEN_DONE census, targeted constraints, quick gate and five-test ratios ready' > "$D/verdict.txt"

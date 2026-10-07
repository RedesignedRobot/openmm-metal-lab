#!/bin/sh
set -eu
root=/tmp/openmm-metal-bench/ultra-m29-resident
tools=/tmp/openmm-metal-bench/ultra-tools
base=/tmp/openmm-metal-bench/ultra-int028
[ -f /tmp/openmm-metal-bench/READY ]
"$tools/ab.sh" "$root/kstep-screen" 2 15 gbsa,rf,pme,amber20-dhfr \
    base-s="$base/venv/bin/python:Metal:single" \
    kstep-s="$root/venv/bin/python:Metal:single" \
    base-m="$base/venv/bin/python:Metal:mixed" \
    kstep-m="$root/venv/bin/python:Metal:mixed" \
    opencl="$base/venv/bin/python:OpenCL:single"
"$root/venv/bin/python" "$tools/summarize.py" "$root/kstep-screen" kstep-s/base-s kstep-m/base-m kstep-s/opencl kstep-m/opencl > "$root/kstep-screen-summary.txt"

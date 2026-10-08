#!/bin/sh
set -eu
root=/tmp/openmm-metal-bench/ultra-m29-resident
bench=/tmp/openmm-metal-bench/ultra-base/benchmarks
base=/tmp/openmm-metal-bench/ultra-int028
for tree in "$base" "$root"; do
    for precision in single mixed; do
        "$tree/venv/bin/python" "$root/smoke.py" "$bench" Metal "$precision"
    done
done
"$base/venv/bin/python" "$root/smoke.py" "$bench" OpenCL single

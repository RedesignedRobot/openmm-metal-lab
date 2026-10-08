#!/bin/sh
set -eu
root=/tmp/openmm-metal-bench
lane=$root/ultra-m29-nonbonded
bench=$root/ultra-base/benchmarks
for tree in "$root/ultra-int028" "$@"; do
    for precision in single mixed; do
        "$tree/venv/bin/python" "$lane/smoke.py" "$bench" Metal "$precision" apoa1rf
    done
done
"$root/ultra-int028/venv/bin/python" "$lane/smoke.py" "$bench" OpenCL single apoa1rf

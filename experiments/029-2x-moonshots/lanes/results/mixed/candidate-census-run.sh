#!/bin/sh
set -eu
D=/tmp/openmm-metal-bench/ultra-m29-mixed-census
OUT=/tmp/openmm-metal-bench/ultra-m29-mixed/census-v1
mkdir -p "$OUT"
cp "$D/BUILT" "$D/blobs.txt" "$OUT/"
cd /tmp/openmm-metal-bench/ultra-base/benchmarks
unset OPENMM_METAL_CENSUS_SPLIT
for precision in single mixed; do
    OPENMM_METAL_CENSUS=1 "$D/venv/bin/python" benchmark.py --platform Metal --precision "$precision" --test gbsa --seconds 3 --style table > "$OUT/$precision.out" 2> "$OUT/$precision.err"
done

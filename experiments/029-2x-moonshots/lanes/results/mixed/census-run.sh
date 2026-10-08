#!/bin/sh
set -eu
D=/tmp/openmm-metal-bench/ultra-m29-mixed-census
B=/tmp/openmm-metal-bench/ultra-base/benchmarks
OUT=/tmp/openmm-metal-bench/ultra-m29-mixed/census
mkdir -p "$OUT"
cd "$B"
for split in fused split; do
    for precision in single mixed; do
        if [ "$split" = split ]; then export OPENMM_METAL_CENSUS_SPLIT=1; else unset OPENMM_METAL_CENSUS_SPLIT; fi
        OPENMM_METAL_CENSUS=1 "$D/venv/bin/python" benchmark.py --platform Metal --precision "$precision" --test gbsa --seconds 3 --style table > "$OUT/$split-$precision.out" 2> "$OUT/$split-$precision.err"
    done
done

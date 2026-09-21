#!/bin/sh
set -eu

# Gate script for Experiment 010: computeNonbonded Kernel Benchmark
# Builds and runs steps 2 to 4 from the committed captures and exits nonzero
# if numerical agreement fails stated tolerance (< 10 ppm) or mutation tests fail.

DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-/tmp/010-compute-nonbonded-results.json}"

echo "Building experiment 010 harness..."
swiftc -O "$DIR/harness.swift" -o "$DIR/harness"

echo "Executing harness verification and benchmark..."
"$DIR/harness" --out "$OUT" --captures-dir "$DIR/captures" --kernels-dir "$DIR/kernels"

echo "Gate passed: Numerical agreement within 10 ppm and mutation tests verified."
echo "Results written to: $OUT"

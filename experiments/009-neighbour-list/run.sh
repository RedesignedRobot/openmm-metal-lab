#!/bin/sh
set -eu

# Gate script for Experiment 009: Neighbour List Kernel Benchmark
# Builds and runs steps 2 to 4 from the committed captures and exits nonzero
# if any interaction set differs.

DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-/tmp/009-neighbour-list-results.json}"

echo "Building experiment 009 harness..."
swiftc -O "$DIR/harness.swift" -o "$DIR/harness"

echo "Executing harness verification and benchmark..."
"$DIR/harness" --out "$OUT" --captures-dir "$DIR/captures" --kernels-dir "$DIR/kernels"

echo "Gate passed: 100% interaction set agreement verified."
echo "Results written to: $OUT"

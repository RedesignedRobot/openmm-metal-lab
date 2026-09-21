#!/bin/sh
set -eu

# Gate script for Experiment 010c: Close computeNonbonded gap on Apple M2
# Verifies numerical agreement within 10.0 ppm tolerance against reference forces,
# verifies mutation gate detection, and executes benchmark parity and ablation suites.

DIR="$(cd "$(dirname "$0")" && pwd)"

DEFAULT_OUT="/tmp/results-010c.json"
OUT="${1:-$DEFAULT_OUT}"

echo "Building experiment 010c harness..."
swiftc -O "$DIR/harness.swift" -o "$DIR/harness"

echo "Executing harness verification and benchmark..."
"$DIR/harness" --out "$OUT" --captures-dir "$DIR/../010-compute-nonbonded/captures" --kernels-dir "$DIR/kernels"

echo "Gate passed: Numerical agreement within 10.0 ppm and mutation tests verified."
echo "Results written to: $OUT"

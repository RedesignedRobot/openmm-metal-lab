#!/bin/sh
set -eu

# Gate script for Experiment 010b: computeNonbonded M2 Gap Investigation
# Verifies numerical agreement within 10.0 ppm tolerance against reference forces,
# verifies mutation gate detection, and executes benchmark parity and ablation suites.

DIR="$(cd "$(dirname "$0")" && pwd)"

# Detect chip name for default output filename
CHIP_RAW="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "Apple")"
if echo "$CHIP_RAW" | grep -q "M3 Ultra"; then
    DEFAULT_OUT="$DIR/results-m3ultra.json"
elif echo "$CHIP_RAW" | grep -q "M2"; then
    DEFAULT_OUT="$DIR/results-m2.json"
else
    DEFAULT_OUT="$DIR/results.json"
fi

OUT="${1:-$DEFAULT_OUT}"

echo "Building experiment 010b harness..."
swiftc -O "$DIR/harness.swift" -o "$DIR/harness"

echo "Executing harness verification and benchmark..."
"$DIR/harness" --out "$OUT" --captures-dir "$DIR/../010-compute-nonbonded/captures" --kernels-dir "$DIR/kernels"

echo "Gate passed: Numerical agreement within 10.0 ppm and mutation tests verified."
echo "Results written to: $OUT"

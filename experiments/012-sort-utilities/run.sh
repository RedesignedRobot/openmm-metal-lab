#!/bin/sh
set -eu

# Gate script for Experiment 012: Sort and Utility Kernels (Metal vs Apple OpenCL)
# Builds and runs Steps 1 to 5 from captures and exits nonzero
# if numerical agreement fails or mutation tests fail.

DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-/tmp/012-sort-utilities-results.json}"

echo "Compiling Experiment 012 harness..."
swiftc -O "$DIR/harness.swift" \
    -framework Metal -framework OpenCL -framework Foundation \
    -o /tmp/012-harness

echo "Executing harness verification and benchmark..."
/tmp/012-harness --out "$OUT" --captures-dir "$DIR/captures" --kernels-dir "$DIR/kernels" --repeats 25

echo "Gate passed: Numerical agreement exact/within tolerances and all mutation gates verified."
echo "Results written to: $OUT"

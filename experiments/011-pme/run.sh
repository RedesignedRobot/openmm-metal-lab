#!/bin/sh
set -eu

# Gate script for Experiment 011: Reciprocal-space PME Benchmark on Metal vs OpenCL
# Builds and runs Steps 2 to 4 from committed captures and exits nonzero
# if numerical agreement fails stated tolerance (< 10 ppm) or mutation tests fail.

DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-/tmp/011-pme-results.json}"

echo "Compiling VkFFT Metal and OpenCL helper objects..."
clang++ -c -std=c++17 -O3 -Wno-deprecated-declarations \
    -I"$DIR/metal-cpp" -I"$DIR/vkFFT" \
    "$DIR/vkfft_metal.cpp" -o /tmp/vkfft_metal.o

clang++ -c -std=c++17 -O3 -Wno-deprecated-declarations \
    -I"$DIR/vkFFT" \
    "$DIR/vkfft_opencl.cpp" -o /tmp/vkfft_opencl.o

echo "Compiling Experiment 011 harness..."
swiftc -O "$DIR/harness.swift" \
    /tmp/vkfft_metal.o /tmp/vkfft_opencl.o \
    -lc++ \
    -framework Metal -framework MetalPerformanceShadersGraph -framework OpenCL -framework Foundation \
    -o /tmp/011-harness

echo "Executing harness verification and benchmark..."
/tmp/011-harness --out "$OUT" --captures-dir "$DIR/captures" --kernels-dir "$DIR/kernels" --repeats 25

echo "Gate passed: Numerical agreement within stated tolerances and mutation tests verified."
echo "Results written to: $OUT"

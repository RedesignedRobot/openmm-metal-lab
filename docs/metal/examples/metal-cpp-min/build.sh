#!/usr/bin/env bash
set -euo pipefail

SDK_PATH=$(xcrun --show-sdk-path)
METAL_REF_PATH="/Users/mas/code/metal-ref"

clang++ -std=c++17 \
    -isysroot "${SDK_PATH}" \
    -I"${METAL_REF_PATH}" \
    -framework Metal \
    -framework Foundation \
    main.cpp -o min_compute

./min_compute

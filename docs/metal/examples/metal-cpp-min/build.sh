#!/usr/bin/env bash
set -euo pipefail

SDK_PATH=$(xcrun --show-sdk-path)
# Point METAL_CPP_DIR at an unpacked metal-cpp (https://developer.apple.com/metal/cpp/).
METAL_REF_PATH="${METAL_CPP_DIR:?set METAL_CPP_DIR to the metal-cpp directory}"

clang++ -std=c++17 \
    -isysroot "${SDK_PATH}" \
    -I"${METAL_REF_PATH}" \
    -framework Metal \
    -framework Foundation \
    main.cpp -o min_compute

./min_compute

#!/usr/bin/env bash
set -euo pipefail

EXPERIMENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${EXPERIMENT_DIR}"

echo "Building census harness with swiftc..."
swiftc census.swift -o census

echo "Running census harness on this system..."
./census

echo "Census complete."
exit 0

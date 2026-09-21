#!/bin/sh
set -eu

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

echo "Building census harness..."
swiftc -O census.swift -o census

echo "Running census harness..."
./census

exit 0

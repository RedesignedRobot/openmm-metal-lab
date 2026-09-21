#!/bin/sh
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

# Compile Swift harness using system Command Line Tools
swiftc -O agreement.swift -o agreement

# Run harness
./agreement "$@"

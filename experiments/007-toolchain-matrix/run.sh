#!/bin/sh
set -eu

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

if [ ! -f harness ] || [ harness.swift -nt harness ]; then
    echo "Compiling harness.swift..."
    swiftc -O harness.swift -o harness
fi

./harness "$@"

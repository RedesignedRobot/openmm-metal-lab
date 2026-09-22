#!/bin/sh
# usage: run.sh [accuracy|convert|census|timing|all] [--verbose]
# Output goes to stdout and to results-<chip>-<UTC time>.md next to this script.
# The timing section waits (up to IDLE_WAIT seconds, default 1800) until no ninja, clang or
# cc1plus process runs, then runs anyway and the log marks the timing as contended.
set -eu

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

if [ ! -d openmm-kernels ]; then
    echo "openmm-kernels/ is missing: run fetch-kernels.sh where the OpenMM working copy lives." >&2
    exit 1
fi

if [ ! -f harness ] || [ harness.swift -nt harness ]; then
    echo "Compiling harness.swift..." >&2
    swiftc -O harness.swift -o harness
fi

section="${1:-all}"
[ $# -gt 0 ] && shift
chip="$(sysctl -n machdep.cpu.brand_string | tr -d ' ')"
log="results-$chip-$(date -u +%Y%m%dT%H%M%SZ).md"

wait_for_idle() {
    waited=0
    limit="${IDLE_WAIT:-1800}"
    while pgrep -q 'ninja|clang|cc1plus' && [ "$waited" -lt "$limit" ]; do
        echo "Build processes running, waiting ($waited s of $limit)..." >&2
        sleep 30
        waited=$((waited + 30))
    done
}

{
    case "$section" in
        timing)
            wait_for_idle
            ./harness timing "$@"
            ;;
        all)
            ./harness accuracy "$@"
            ./harness convert "$@" | sed '1,/^## /{/^## /!d;}'
            ./harness census "$@" | sed '1,/^## /{/^## /!d;}'
            wait_for_idle
            ./harness timing "$@" | sed '1,/^## /{/^## /!d;}'
            ;;
        *)
            ./harness "$section" "$@"
            ;;
    esac
} | tee "$log"
echo "Wrote $log" >&2

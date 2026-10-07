#!/bin/sh
# Diagnostic only. One screen, no retries, no correctness claim.
set -eu
ROOT=/tmp/openmm-metal-bench/ultra-r3-gbown-probe
TOOLS=/tmp/openmm-metal-bench/ultra-tools
BASE=/tmp/openmm-metal-bench/ultra-r2-accum-gb-s
ARCHIVE=$HOME/code/metal/lab/experiments/029-2x-moonshots/lanes/r3-gbown-artifacts

guard() {
    hour=$(date -u +%H)
    day=$(date -u +%Y%m%d)
    [ "$day" -ge 20260928 ] && [ "$hour" -ge 7 ] && [ "$hour" -lt 23 ] || {
        echo "Refused: this diagnostic may start only after 2026-09-28 07:00Z, before 23:00Z."
        exit 2
    }
}

guard
[ ! -e "$ROOT/screen" ] || { echo "Screen already exists; no automatic repeat."; exit 2; }
cmp "$BASE/BUILT" "$ARCHIVE/BUILT-r2.txt"
"$TOOLS/sync.sh" "$ROOT/source-input" "$ROOT"
guard
"$TOOLS/build.sh" "$ROOT"
guard
cp "$ROOT/BUILT" "$ARCHIVE/BUILT-direction-probe.txt"
cmp "$BASE/BUILT" "$ARCHIVE/BUILT-r2.txt"
"$ROOT/tools/ab-fixed.sh" "$ROOT/screen" 2 15 gbsa \
    "baseS=$BASE/venv/bin/python:Metal:single" \
    "baseM=$BASE/venv/bin/python:Metal:mixed" \
    "probeS=$ROOT/venv/bin/python:Metal:single" \
    "probeM=$ROOT/venv/bin/python:Metal:mixed"
"/tmp/openmm-metal-bench/env/bin/python3" "$ROOT/tools/report-probe.py"

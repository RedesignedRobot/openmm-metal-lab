#!/bin/sh
# Runs on the mini, inside a synced and installed OpenMM tree.
# usage: bench.sh <platform> <seconds> <tests>
# Writes one JSON file per run to ~/lab/results/ and prints its path.
set -eu
platform="${1:-OpenCL}"
seconds="${2:-30}"
tests="${3:-rf,pme,apoa1rf,apoa1pme,apoa1ljpme}"
name="$(basename "$PWD")"
mkdir -p "$HOME/lab/results"
out="$HOME/lab/results/$(date -u +%Y%m%dT%H%M%SZ)-$name-$platform.json"
cd examples/benchmarks
python benchmark.py --platform "$platform" --test "$tests" --seconds "$seconds" \
  --style table --outfile "$out"
echo "$out"

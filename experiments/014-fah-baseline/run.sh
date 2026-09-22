#!/bin/sh
# Baseline for the three FAHBench work units on the M2: OpenCL single and CPU (mixed).
# One job at a time; nothing else runs on the mini during it.
set -eu
out="results-m2-$(date -u +%Y%m%dT%H%M%SZ).jsonl"
for wu in dhfr-implicit dhfr nav; do
  for p in "OpenCL single" "CPU mixed"; do
    set -- $p
    ~/lab/venv/bin/python fahwu.py "$HOME/lab/fah-wu/$wu" "$1" "$2" 60 | tee -a "$out"
  done
done

#!/bin/sh
# Barostat and temperature flake probe, stage 1, one correctness hold (lease.sh --correctness, several minutes):
# initial-temperature readback on Metal against Reference for the same seeds, then one seeded molecular-gas run per
# platform and tree to time stage 2. Output: stage1.jsonl, one line per run (probe.py).
set -u
B=/tmp/openmm-metal-bench
P=$B/ultra-infra/baro/probe.py
INT=$B/ultra-integrated/venv/bin/python
BASE=$B/ultra-base/venv/bin/python
out=$B/ultra-infra/baro/stage1.jsonl
: > "$out"
for mode in init drude; do
    for platform in Reference Metal; do
        "$INT" "$P" $mode $platform single 1 2 3 4 5 6 7 8 9 10 >> "$out" 2>&1
    done
done
"$BASE" "$P" init Metal single 1 2 3 4 5 >> "$out" 2>&1
for mode in gas1 gas0; do
    "$INT" "$P" $mode Metal single 1 >> "$out" 2>&1
    "$BASE" "$P" $mode Metal single 1 >> "$out" 2>&1
    "$INT" "$P" $mode Reference single 1 >> "$out" 2>&1
done
echo "stage1 done $(date -u +%H:%M:%SZ)" >> "$out"

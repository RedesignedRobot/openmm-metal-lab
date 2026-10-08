#!/bin/sh
# Barostat flake probe, stage 2a, one correctness hold (CPU only, about 10 min): 200 seeded molecular-gas runs per
# mode on Reference, the upstream expectation for testMolecularGas's failure rate. Output: stage2a.jsonl.
B=/tmp/openmm-metal-bench
out=$B/ultra-infra/baro/stage2a.jsonl
: > "$out"
for mode in gas0 gas1; do
    $B/ultra-integrated/venv/bin/python $B/ultra-infra/baro/probe.py $mode Reference single $(seq 1 200) >> "$out" 2>&1
done
echo "stage2a done $(date -u +%H:%M:%SZ)" >> "$out"

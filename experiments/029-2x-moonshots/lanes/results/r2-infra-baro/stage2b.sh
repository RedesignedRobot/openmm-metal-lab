#!/bin/sh
# Barostat flake probe, stage 2b, one correctness hold (about 12 min): the -j2 race check, then 10 seeded
# molecular-gas runs per mode on Metal single, ultra-integrated. The race check runs gas0 seed 1 as two processes at
# once; stage 1 ran it alone on the same tree (pressure 2.71522531567585 on x). Any difference is scheduling-dependent.
# Output: stage2b.jsonl.
B=/tmp/openmm-metal-bench
PY=$B/ultra-integrated/venv/bin/python
P=$B/ultra-infra/baro/probe.py
out=$B/ultra-infra/baro/stage2b.jsonl
: > "$out"
$PY $P gas0 Metal single 1 > "$out.race1" 2>&1 &
first=$!
$PY $P gas0 Metal single 1 > "$out.race2" 2>&1
wait $first
sed 's/"mode"/"race": 1, "mode"/' "$out.race1" "$out.race2" >> "$out"
rm -f "$out.race1" "$out.race2"
for mode in gas0 gas1; do
    $PY $P $mode Metal single 2 3 4 5 6 7 8 9 10 11 >> "$out" 2>&1
done
echo "stage2b done $(date -u +%H:%M:%SZ)" >> "$out"

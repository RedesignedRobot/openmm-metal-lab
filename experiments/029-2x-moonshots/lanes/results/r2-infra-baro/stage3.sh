#!/bin/sh
# Barostat flake probe, stage 3, one correctness hold (about 10 min): testMolecularGas(rigid) failure rate on Metal
# single, ultra-integrated (seeds 101-160) against ultra-base, which predates the fused LangevinMiddle cf1d7fc14
# (seeds 201-260). Eight processes at once: stage 2b showed a run's result doesn't depend on what runs beside it.
# Output: stage3.jsonl.
B=/tmp/openmm-metal-bench
P=$B/ultra-infra/baro/probe.py
out=$B/ultra-infra/baro/stage3.jsonl
pids=""
for tree in integrated base; do
    first=101
    [ $tree = base ] && first=201
    for part in 0 1 2 3; do
        start=$((first + 15*part))
        $B/ultra-$tree/venv/bin/python $P gas1 Metal single $(seq $start $((start + 14))) > "$out.$tree$part" 2>&1 &
        pids="$pids $!"
    done
done
for pid in $pids; do wait $pid; done
for tree in integrated base; do
    for part in 0 1 2 3; do
        sed "s/\"mode\"/\"tree\": \"$tree\", \"mode\"/" "$out.$tree$part"
        rm -f "$out.$tree$part"
    done
done > "$out"
echo "stage3 done $(date -u +%H:%M:%SZ)" >> "$out"

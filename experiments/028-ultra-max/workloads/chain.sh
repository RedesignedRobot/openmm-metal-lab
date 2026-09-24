#!/bin/sh
# Items 3, 4 and 5 in order, after item 1's driver finishes.
set -eu
D=/tmp/openmm-metal-bench/ultra-workloads
until grep -q '^done' "$D/mixed-vs-cpu.out" 2>/dev/null; do sleep 20; done
"$D/wl-run.sh" "$D/sync.jsonl" 3 \
    "sync Metal custom-sum" "sync OpenCL custom-sum" "sync Metal custom-nosum" "sync OpenCL custom-nosum" \
    "sync Metal loop-energy" "sync OpenCL loop-energy" "sync Metal loop-nosync" "sync OpenCL loop-nosync" \
    "sync Metal pipelined" "sync OpenCL pipelined"
"$D/wl-run.sh" "$D/ctx.jsonl" 5 \
    "ctx Metal pme unique" "ctx OpenCL pme unique" "ctx Metal apoa1pme unique" "ctx OpenCL apoa1pme unique" \
    "ctx Metal pme proc" "ctx OpenCL pme proc" "ctx Metal apoa1pme proc" "ctx OpenCL apoa1pme proc"
"$D/wl-run.sh" "$D/min.jsonl" 3 \
    "min Metal mixed 200" "min CPU mixed 200" "min Metal single 200" "min OpenCL single 200" \
    "min Metal mixed 0" "min CPU mixed 0" "min Metal single 0" "min OpenCL single 0"
echo "chain done"

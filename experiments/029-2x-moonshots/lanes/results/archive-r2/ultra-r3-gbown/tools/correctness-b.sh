#!/bin/sh
set -eu
TREE=/tmp/openmm-metal-bench/ultra-r3-gbown-b
TOOLS=/tmp/openmm-metal-bench/ultra-tools
case "$(date -u +%H)" in 00|01|02|03|04|05|06) echo 'night slot: correctness refused'; exit 2;; esac
/tmp/openmm-metal-bench/env/bin/ctest --test-dir "$TREE/build" --output-on-failure -j2 \
    -R '^TestMetalOwnedGB(Single|Mixed)$' > "$TREE/owned-results.log" 2>&1 || { cat "$TREE/owned-results.log"; exit 1; }
cat "$TREE/owned-results.log"
"$TREE/venv/bin/python" "$TOOLS/detforces.py" /tmp/openmm-metal-bench/ultra-base/benchmarks "$TREE/detforces.txt"
"$TREE/venv/bin/python" /tmp/openmm-metal-bench/ultra-r3-gbown/tools/forces-gb.py --md 100 \
    /tmp/openmm-metal-bench/ultra-base/benchmarks "$TREE/forces-md100.txt" /tmp/openmm-metal-bench/ultra-base/forces-md100.txt
echo PASS

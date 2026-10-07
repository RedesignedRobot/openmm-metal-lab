#!/bin/sh
set -eu
TREE=/tmp/openmm-metal-bench/ultra-r3-gbown-direct
TOOLS=/tmp/openmm-metal-bench/ultra-tools
case "$(date -u +%H)" in 00|01|02|03|04|05|06) echo 'night slot: final correctness refused; requeue after 07:00Z'; exit 2;; esac
/tmp/openmm-metal-bench/env/bin/ctest --test-dir "$TREE/build" --output-on-failure -j2 \
    -R '^TestMetal(OwnedGB|GBSAOBCForce|CustomGBForce|NonbondedForce)(Single|Mixed)$' > "$TREE/native-results.log" 2>&1 || { cat "$TREE/native-results.log"; exit 1; }
cat "$TREE/native-results.log"
"$TREE/venv/bin/python" "$TOOLS/detforces.py" /tmp/openmm-metal-bench/ultra-base/benchmarks "$TREE/detforces.txt"
GATE_HELD=1 "$TOOLS/gate.sh" --quick "$TREE"
echo 'FINAL CORRECTNESS PASS'

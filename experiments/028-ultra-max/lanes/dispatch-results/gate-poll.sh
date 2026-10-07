#!/bin/sh
T=/tmp/openmm-metal-bench/ultra-tools
D=/tmp/openmm-metal-bench/ultra-dispatch
export PATH=/tmp/openmm-metal-bench/env/bin:$PATH
echo "start $(date -u +%H:%M:%SZ) $(uptime)"
$T/lease.sh --correctness ultra-dispatch "TestMetalCommandBatching t2" ctest --test-dir $D/t2/build -R TestMetalCommandBatching --output-on-failure 2>&1 | grep -E "Commits per step|tests passed|Failed|Passed"
$T/gate.sh --quick $D/t2 > $D/t2/gate.out 2>&1
echo "gate $(tail -1 $D/t2/gate.out) $(date -u +%H:%M:%SZ)"

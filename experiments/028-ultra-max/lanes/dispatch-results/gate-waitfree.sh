#!/bin/sh
T=/tmp/openmm-metal-bench/ultra-tools
D=/tmp/openmm-metal-bench/ultra-dispatch
B=/tmp/openmm-metal-bench/ultra-base/benchmarks
export PATH=/tmp/openmm-metal-bench/env/bin:$PATH
echo "start $(date -u +%H:%M:%SZ) $(uptime)"
$T/lease.sh --correctness ultra-dispatch "TestMetalCommandBatching and md100 t5 vs base" /bin/sh -c "
ctest --test-dir $D/t5/build -R TestMetalCommandBatching --output-on-failure 2>&1 | grep -E 'Commits per step|tests passed|Failed|Passed'
echo t5 && $D/t5/venv/bin/python $D/md100.py $B gbsa,rf,pme single 2>&1
echo base && /tmp/openmm-metal-bench/ultra-base/venv/bin/python $D/md100.py $B gbsa,rf,pme single 2>&1"
$T/gate.sh --quick $D/t5 > $D/t5/gate.out 2>&1
echo "gate $(tail -1 $D/t5/gate.out) $(date -u +%H:%M:%SZ)"

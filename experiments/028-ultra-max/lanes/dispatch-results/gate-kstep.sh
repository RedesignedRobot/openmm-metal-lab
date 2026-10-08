#!/bin/sh
T=/tmp/openmm-metal-bench/ultra-tools
D=/tmp/openmm-metal-bench/ultra-dispatch
B=/tmp/openmm-metal-bench/ultra-base/benchmarks
export PATH=/tmp/openmm-metal-bench/env/bin:$PATH
echo "start $(date -u +%H:%M:%SZ) $(uptime)"
$T/lease.sh --correctness ultra-dispatch "md100 t10 (waitfree+k)" /bin/sh -c "echo t10 && $D/t10/venv/bin/python $D/md100.py $B gbsa,rf,pme single 2>&1"
$T/gate.sh $D/t10 > $D/t10/gate.out 2>&1
echo "gate $(tail -1 $D/t10/gate.out) $(date -u +%H:%M:%SZ)"

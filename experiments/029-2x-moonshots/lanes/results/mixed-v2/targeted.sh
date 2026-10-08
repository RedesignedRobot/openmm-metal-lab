#!/bin/sh
set -eu
export PATH=/tmp/openmm-metal-bench/env/bin:$PATH
D=/tmp/openmm-metal-bench/ultra-m29-mixed-v2
export OPENMM_PLUGIN_DIR="$D/prefix/lib/plugins"
cd "$D/build"
ctest --no-tests=error --output-on-failure -R '^TestMetal(MixedPrecision|Settle|CustomIntegrator|VerletIntegrator|LangevinMiddleIntegrator|CMMotionRemover)(Single|Mixed)$'

unset OPENMM_PLUGIN_DIR
B=/tmp/openmm-metal-bench/ultra-int028
BENCH=/tmp/openmm-metal-bench/ultra-base/benchmarks
for tree in "$B" "$D"; do
    for precision in single mixed; do
        "$tree/venv/bin/python" "$D/smoke.py" "$BENCH" Metal "$precision"
    done
done
"$B/venv/bin/python" "$D/smoke.py" "$BENCH" OpenCL single

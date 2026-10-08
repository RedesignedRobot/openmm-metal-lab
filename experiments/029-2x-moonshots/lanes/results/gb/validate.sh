#!/bin/sh
set -eu
export PATH=/tmp/openmm-metal-bench/env/bin:$PATH
D=/tmp/openmm-metal-bench/ultra-m29-gb
"$D/venv/bin/python" /tmp/openmm-metal-bench/ultra-tools/forces.py /tmp/openmm-metal-bench/ultra-base/benchmarks "$D/forces.txt" /tmp/openmm-metal-bench/ultra-base/forces.txt
ctest --test-dir "$D/build" --no-tests=error --output-on-failure -j1 -R '^TestMetal(GBSAOBCForce|CustomGBForce)(Single|Mixed)$' > "$D/targeted.txt" 2>&1
"$D/venv/bin/python" "$D/determinism-five.py" > "$D/determinism.txt" 2>&1
printf 'PASS\n' > "$D/validation.verdict"

#!/bin/sh
set -eu
D=/tmp/openmm-metal-bench/ultra-m29-unified
T=/tmp/openmm-metal-bench/ultra-tools
test -f /tmp/openmm-metal-bench/READY
test -f "$D/BUILT"
export PATH=/tmp/openmm-metal-bench/env/bin:$PATH
"$T/lease.sh" --correctness ultra-m29-unified 'CPU FFT transform oracle' ctest --test-dir "$D/build" --output-on-failure -R '^TestMetalFFTSingle$'
"$T/gate.sh" --quick "$D"
"$T/lease.sh" --correctness ultra-m29-unified 'CPU FFT md100 forces' "$D/venv/bin/python" "$T/forces.py" --md 100 /tmp/openmm-metal-bench/ultra-base/benchmarks "$D/forces-md100.txt" /tmp/openmm-metal-bench/ultra-base/forces-md100.txt
"$T/lease.sh" --correctness ultra-m29-unified 'CPU FFT deterministic forces' "$D/venv/bin/python" "$T/detforces.py" /tmp/openmm-metal-bench/ultra-base/benchmarks "$D/detforces.txt"
echo 'CANDIDATE CORRECTNESS COMPLETE'

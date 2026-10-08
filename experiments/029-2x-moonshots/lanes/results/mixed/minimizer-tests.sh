#!/bin/sh
set -eu
export PATH=/tmp/openmm-metal-bench/env/bin:$PATH
D=${1:-/tmp/openmm-metal-bench/ultra-m29-mixed-minimizer}
export OPENMM_PLUGIN_DIR="$D/prefix/lib/plugins"
cd "$D/build"
ctest --no-tests=error --output-on-failure -R "${2:-^TestMetalLocalEnergyMinimizer(Single|Mixed)$}"

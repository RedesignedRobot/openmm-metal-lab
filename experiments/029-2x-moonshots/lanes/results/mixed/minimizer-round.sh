#!/bin/sh
set -eu
D=/tmp/openmm-metal-bench/ultra-m29-mixed
T=/tmp/openmm-metal-bench/ultra-tools
M=/tmp/openmm-metal-bench/ultra-m29-mixed-minimizer
export PATH=/tmp/openmm-metal-bench/env/bin:$PATH
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
unset PYTHONPATH OPENMM_PLUGIN_DIR
stage=tests
trap 'rc=$?; if [ "$rc" -ne 0 ]; then echo "FAILED stage=$stage rc=$rc" > "$D/minimizer-verdict.txt"; fi' EXIT
"$T/lease.sh" --correctness ultra-m29-mixed 'Bet 4 focused minimizer tests' /bin/sh "$D/minimizer-tests.sh" "$M" > "$D/minimizer-tests.out" 2>&1
stage=timings
"$T/lease.sh" ultra-m29-mixed 'Bet 4 apoa1pme minimizer 200 iterations' /bin/sh "$D/minimizer-run.sh" "$M" > "$D/minimizer-timings.out" 2>&1
echo MINIMIZER_DONE > "$D/minimizer-verdict.txt"

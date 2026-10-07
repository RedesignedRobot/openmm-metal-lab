#!/bin/sh
set -eu
D=/tmp/openmm-metal-bench/ultra-m29-mixed
T=/tmp/openmm-metal-bench/ultra-tools
stage=build
trap 'rc=$?; if [ "$rc" -ne 0 ]; then echo "FAILED stage=$stage rc=$rc" > "$D/candidate-census-verdict.txt"; fi' EXIT
"$T/build.sh" /tmp/openmm-metal-bench/ultra-m29-mixed-census > "$D/candidate-census-build.out" 2>&1
stage=census
"$T/lease.sh" ultra-m29-mixed 'Bet 4 cooperative candidate census' /bin/sh "$D/candidate-census-run.sh" > "$D/candidate-census.out" 2>&1
echo CANDIDATE_CENSUS_DONE > "$D/candidate-census-verdict.txt"

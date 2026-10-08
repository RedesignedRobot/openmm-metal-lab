#!/bin/sh
set -eu
ROOT=$HOME/lab/ultra-m2.noindex
D=$ROOT/m29-mixed-minimizer-evidence
mkdir -p "$D/results"
"$ROOT/tools/m2-lease.sh" --correctness ultra-m29-mixed "M2 minimizer Mixed focused test" /bin/sh "$D/minimizer-m2-test.sh" > "$D/results/targeted.out" 2>&1
"$ROOT/tools/m2-lease.sh" ultra-m29-mixed "Bet 4 minimizer 200 iterations" /bin/sh "$D/minimizer-m2-run.sh"

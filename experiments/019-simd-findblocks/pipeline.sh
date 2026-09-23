#!/bin/sh
# Runs on the mini after build.sh, holding the machine lease for about 25 minutes:
#   1. eqcheck.py with both installs in single and mixed, then compare.py
#   2. the Metal ctest of the after build (both precisions are separate tests)
# The benchmarks are run.py's job, which takes the lease per (test, precision) pair.
# Launch detached from sh at nice 0:  sh -c "nohup sh pipeline.sh > pipeline.log 2>&1 &"
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lease.sh"
lab="$HOME/lab"
out="$lab/simd-019"
bench="$out/benchmarks"
before="$lab/venv-openmm-simd-base/bin/python"
after="$lab/venv-openmm-simd/bin/python"
status() { echo "$(date -u +%FT%TZ) $*" >> "$out/pipeline.status"; }

lease "eqcheck+ctest"
status start
for precision in single mixed; do
    for label in before after; do
        eval py=\$$label
        "$py" "$here/eqcheck.py" "$bench" "$lab/fah-wu" "$precision" "$out/eq-$label-$precision.npz" \
            > "$out/eq-$label-$precision.log" 2>&1
        status "eqcheck $label $precision exit $?"
    done
    "$after" "$here/compare.py" "$out/eq-before-$precision.npz" "$out/eq-after-$precision.npz" > "$out/eq-compare-$precision.txt" 2>&1
    status "compare $precision exit $?"
done

cd "$lab/openmm-simd/build"
ctest -R TestMetal --timeout 1800 > "$out/ctest.txt" 2>&1
status "ctest exit $?"
unlease
status ALL_DONE

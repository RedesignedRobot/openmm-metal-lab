#!/bin/sh
# Bisect of the e08a0b1c6 AMOEBA failures: build.sh on <dir> (already synced to one bisect ref), then the
# 3 failing tests in one correctness ticket, each run alone once more if it fails.
# usage: bisect.sh <dir> <label>
B=/tmp/openmm-metal-bench
D=$1
label=$2
TESTS='^TestMetalAmoeba(ExtrapolatedPolarization(Single|Mixed)|MultipoleForceMixed)$'
echo "$(date -u +%H:%M:%SZ) build.sh $D ($label, $(cat $D/src/.commit))"
$B/ultra-tools/build.sh $D > $D/build.out 2>&1 || { echo "BUILD FAILED"; tail -20 $D/build.out; exit 1; }
echo "$(date -u +%H:%M:%SZ) built $(sed -n 's/^commit //p' $D/BUILT | cut -c1-9)"
cd /
exec $B/ultra-tools/lease.sh --correctness ultra-infra "infra: bisect $label, 3 AMOEBA tests" /bin/sh -c '
    PATH=/tmp/openmm-metal-bench/env/bin:$PATH
    ctest --test-dir "$1/build" -R "$2" --timeout 600 --output-on-failure
    echo "BISECT CTEST EXIT $?"' sh $D "$TESTS"

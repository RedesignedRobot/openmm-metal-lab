#!/bin/sh
# ctest.sh <variant> <precision>: the variant's Metal tests in one precision (-j 4, as in 022),
# then up to 3 reruns of whatever still fails, one test at a time.
S=/tmp/openmm-metal-bench/verify-p2p3
PATH=/tmp/openmm-metal-bench/env/bin:$PATH
log=$S/logs/ctest-$1-$2
cd $S/v/$1/build || exit 1
{ date -u +%Y-%m-%dT%H:%M:%SZ; uptime; } > $log.log
ctest -R "^TestMetal.*$2\$" -j 4 --output-on-failure >> $log.log 2>&1 && exit 0
for i in 1 2 3; do
    { date -u +%Y-%m-%dT%H:%M:%SZ; uptime; } > $log-rerun$i.log
    ctest --rerun-failed --output-on-failure >> $log-rerun$i.log 2>&1 && exit 0
done
exit 1

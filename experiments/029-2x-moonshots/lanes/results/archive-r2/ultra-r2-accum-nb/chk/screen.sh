#!/bin/sh
# 3x30 of fbb (tree p) and irl (tree q) against ultra-integrated, one ab.sh ticket per test and precision so
# every ticket stays under the 18 minute cap and other lanes interleave.
set -u
cd /tmp/openmm-metal-bench
N=/tmp/openmm-metal-bench/ultra-integrated/venv/bin/python
P=/tmp/openmm-metal-bench/ultra-r2-accum-nb-p/venv/bin/python
Q=/tmp/openmm-metal-bench/ultra-r2-accum-nb-q/venv/bin/python
I=/tmp/openmm-metal-bench/ultra-r2-accum-nb/irl
for t in rf pme apoa1rf apoa1pme amber20-stmv; do
    for pr in single mixed; do
        ./ultra-tools/ab.sh $I/ab-$t-$pr 3 30 $t int=$N:Metal:$pr fbb=$P:Metal:$pr irl=$Q:Metal:$pr > $I/ab-$t-$pr.out 2>&1
        echo "$t $pr exit $?"
    done
done
echo screen done

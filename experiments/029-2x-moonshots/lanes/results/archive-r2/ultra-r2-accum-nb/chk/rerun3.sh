#!/bin/sh
# Rerun the flagged screen rows: rf single (1.7% fbb spread, VM at 93%), rf mixed (round 1 overlapped a build),
# pme single (round 3 overlapped a build). One ab.sh ticket per row, each under the 18 minute cap.
set -u
cd /tmp/openmm-metal-bench
I=/tmp/openmm-metal-bench/ultra-r2-accum-nb/irl
N=/tmp/openmm-metal-bench/ultra-integrated/venv/bin/python
P=/tmp/openmm-metal-bench/ultra-r2-accum-nb-p/venv/bin/python
Q=/tmp/openmm-metal-bench/ultra-r2-accum-nb-q/venv/bin/python
for row in rf:single rf:mixed pme:single; do
    t=${row%:*}; pr=${row#*:}
    ./ultra-tools/ab.sh $I/ab3-$t-$pr 3 30 $t int=$N:Metal:$pr fbb=$P:Metal:$pr irl=$Q:Metal:$pr > $I/ab3-$t-$pr.out 2>&1
    echo "$t $pr exit $?"
done
echo rerun3 done

#!/bin/sh
# Rerun the rf rows: single had a 1.7% spread with the VM at 93%, mixed overlapped a build.
set -u
cd /tmp/openmm-metal-bench
I=/tmp/openmm-metal-bench/ultra-r2-accum-nb/irl
N=/tmp/openmm-metal-bench/ultra-integrated/venv/bin/python
P=/tmp/openmm-metal-bench/ultra-r2-accum-nb-p/venv/bin/python
Q=/tmp/openmm-metal-bench/ultra-r2-accum-nb-q/venv/bin/python
for pr in single mixed; do
    ./ultra-tools/ab.sh $I/ab2-rf-$pr 3 30 rf int=$N:Metal:$pr fbb=$P:Metal:$pr irl=$Q:Metal:$pr > $I/ab2-rf-$pr.out 2>&1
    echo "rf $pr exit $?"
done
echo rerun done

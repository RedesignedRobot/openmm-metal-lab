#!/bin/sh
# 028 nonbonded lane: screen of x-resident 761d5a666 (fixed-point carry) against its parent 6d72c3ae9 (tiles4), Metal single.
# Both arms run tiles4, so the ratio is the x-resident change alone.
D=/tmp/openmm-metal-bench/ultra-nonbonded
X=/tmp/openmm-metal-bench/ultra-nonbonded-xres
grep -q 6d72c3ae9 $D/BUILT || { echo "build of 6d72c3ae9 not ready, skipping"; exit 1; }
grep -q 761d5a666 $X/BUILT || { echo "build of 761d5a666 not ready, skipping"; exit 1; }
exec /tmp/openmm-metal-bench/ultra-tools/ab.sh $D/ab-xres 2 15 apoa1rf,rf,pme,apoa1pme \
    tiles=$D/venv/bin/python:Metal:single \
    xres=$X/venv/bin/python:Metal:single

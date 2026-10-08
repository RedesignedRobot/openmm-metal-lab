#!/bin/sh
# 028 nonbonded lane: x-resident 761d5a666 against 6d72c3ae9 on apoa1rf, Metal single, 3 rounds. ab-xres round 1 on
# apoa1rf ran beside an xctrace at 497% CPU (tiles 219.62 against 301.42 in round 2), so its 1.213 median rests on one clean round.
D=/tmp/openmm-metal-bench/ultra-nonbonded
B=/tmp/openmm-metal-bench/ultra-nonbonded-xres
grep -q 6d72c3ae9 $D/BUILT && grep -q 761d5a666 $B/BUILT || { echo "a build is not ready, skipping"; exit 1; }
exec /tmp/openmm-metal-bench/ultra-tools/ab.sh $D/ab-xresa 3 15 apoa1rf \
    tiles=$D/venv/bin/python:Metal:single \
    xres=$B/venv/bin/python:Metal:single

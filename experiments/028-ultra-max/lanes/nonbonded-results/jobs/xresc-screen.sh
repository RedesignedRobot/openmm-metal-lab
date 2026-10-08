#!/bin/sh
# 028 nonbonded lane: x-resident 761d5a666 against 6d72c3ae9 on cellulose, Metal single (research: largest share of x-side adds removed, 78.6%).
D=/tmp/openmm-metal-bench/ultra-nonbonded
B=/tmp/openmm-metal-bench/ultra-nonbonded-xres
grep -q 6d72c3ae9 $D/BUILT && grep -q 761d5a666 $B/BUILT || { echo "a build is not ready, skipping"; exit 1; }
exec /tmp/openmm-metal-bench/ultra-tools/ab.sh $D/ab-xresc 2 15 amber20-cellulose \
    tiles=$D/venv/bin/python:Metal:single \
    xres=$B/venv/bin/python:Metal:single

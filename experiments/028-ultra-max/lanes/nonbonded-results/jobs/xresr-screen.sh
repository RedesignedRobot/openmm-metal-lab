#!/bin/sh
# 028 nonbonded lane: x-resident 761d5a666 against 6d72c3ae9 on the benchmark tests no other xres screen covers, Metal single.
# RULES' allows no cost over 1% on any test.
D=/tmp/openmm-metal-bench/ultra-nonbonded
B=/tmp/openmm-metal-bench/ultra-nonbonded-xres
grep -q 6d72c3ae9 $D/BUILT && grep -q 761d5a666 $B/BUILT || { echo "a build is not ready, skipping"; exit 1; }
exec /tmp/openmm-metal-bench/ultra-tools/ab.sh $D/ab-xresr 2 15 gbsa,apoa1ljpme,amber20-stmv \
    tiles=$D/venv/bin/python:Metal:single \
    xres=$B/venv/bin/python:Metal:single

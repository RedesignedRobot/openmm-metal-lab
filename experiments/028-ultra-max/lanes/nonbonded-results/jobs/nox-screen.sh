#!/bin/sh
# 028 nonbonded lane: Ultra calibration for the M2 atomics probe. tiles 6d72c3ae9, xres 761d5a666 and the lab probe
# nox 626652d2c (x force written once per warp, forces wrong) on apoa1rf, Metal single.
D=/tmp/openmm-metal-bench/ultra-nonbonded
B=/tmp/openmm-metal-bench/ultra-nonbonded-xres
N=/tmp/openmm-metal-bench/ultra-nonbonded-nox
grep -q 6d72c3ae9 $D/BUILT && grep -q 761d5a666 $B/BUILT && grep -q 626652d2c $N/BUILT || { echo "a build is not ready, skipping"; exit 1; }
exec /tmp/openmm-metal-bench/ultra-tools/ab.sh --rerun-builds $D/ab-nox 2 15 apoa1rf \
    tiles=$D/venv/bin/python:Metal:single \
    xres=$B/venv/bin/python:Metal:single \
    nox=$N/venv/bin/python:Metal:single

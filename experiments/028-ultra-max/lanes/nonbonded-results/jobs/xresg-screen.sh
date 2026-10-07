#!/bin/sh
# 028 nonbonded lane: clean gbsa rerun of x-resident 761d5a666 against 6d72c3ae9, Metal single, 3 rounds. ab-xresr ran
# gbsa beside a build (load 13 to 20) and gave 0.992 (rounds 0.989, 0.996); the M2 read 0.988 (0.974, 1.004).
D=/tmp/openmm-metal-bench/ultra-nonbonded
B=/tmp/openmm-metal-bench/ultra-nonbonded-xres
grep -q 6d72c3ae9 $D/BUILT && grep -q 761d5a666 $B/BUILT || { echo "a build is not ready, skipping"; exit 1; }
exec /tmp/openmm-metal-bench/ultra-tools/ab.sh --rerun-builds $D/ab-xresg 3 15 gbsa \
    tiles=$D/venv/bin/python:Metal:single \
    xres=$B/venv/bin/python:Metal:single

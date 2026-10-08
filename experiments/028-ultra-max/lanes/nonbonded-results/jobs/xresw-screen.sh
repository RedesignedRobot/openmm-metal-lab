#!/bin/sh
# 028 nonbonded lane: x-resident 761d5a666 at the default force launch (40 blocks of 64 per core) and at 1/2 (866af81c1)
# and 1/4 (dcf45d451) of it, against 6d72c3ae9 (tiles4), Metal single. Research emu4w: fewer SIMD groups give longer
# same-x runs on the dhfr-size tests; the cost is occupancy, which is unmeasured. Cellulose is in so this one screen covers the width question on all four tests.
D=/tmp/openmm-metal-bench/ultra-nonbonded
B=/tmp/openmm-metal-bench/ultra-nonbonded-xres
grep -q 6d72c3ae9 $D/BUILT && grep -q 761d5a666 $B/BUILT && grep -q 866af81c1 ${B}2/BUILT && grep -q dcf45d451 ${B}4/BUILT || { echo "a build is not ready, skipping"; exit 1; }
exec /tmp/openmm-metal-bench/ultra-tools/ab.sh $D/ab-xresw 2 15 pme,rf,amber20-dhfr,amber20-cellulose \
    tiles=$D/venv/bin/python:Metal:single \
    xres=$B/venv/bin/python:Metal:single \
    xres2=${B}2/venv/bin/python:Metal:single \
    xres4=${B}4/venv/bin/python:Metal:single

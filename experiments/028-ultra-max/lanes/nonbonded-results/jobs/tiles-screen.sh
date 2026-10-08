#!/bin/sh
# 028 nonbonded lane: screen of commit 6d72c3ae9 (tiles per batch) against ultra-base, Metal single.
# apoa1rf and apoa1pme are above the 1,920-block threshold on the Ultra, so their code is unchanged.
D=/tmp/openmm-metal-bench/ultra-nonbonded
grep -q 6d72c3ae9 $D/BUILT || { echo "build of 6d72c3ae9 not ready, skipping"; exit 1; }
exec /tmp/openmm-metal-bench/ultra-tools/ab.sh $D/ab-tiles 2 15 gbsa,rf,pme \
    base=/tmp/openmm-metal-bench/ultra-base/venv/bin/python:Metal:single \
    tiles=$D/venv/bin/python:Metal:single

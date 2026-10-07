#!/bin/sh
# 028 nonbonded lane: pipeline limits of every saved computeNonbonded source in temps/, with its knob defines.
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
cd /tmp/openmm-metal-bench/ultra-nonbonded
for f in $(grep -l "void computeNonbonded(" temps/*.metal); do
    defs=$(grep -o "^#define \(NB_[A-Z_]*\|THREAD_BLOCK_SIZE\|NUM_ATOMS\|USE_PERIODIC\|USE_CUTOFF\|NUM_TILES_IN_BATCH\)\( [0-9]*\)\{0,1\}$" $f | sed "s/#define //" | tr "\n" " ")
    echo "$(nice -n 10 xcrun swift pipestat.swift computeNonbonded $f 2>&1 | tail -1 | sed 's|^temps/||') | $defs"
done

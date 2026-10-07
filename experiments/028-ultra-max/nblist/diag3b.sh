#!/bin/sh
# nblist: the nblist-related ctests on the dev2 tree (t5) with NB_GATE=1, inside one lease.sh
# --correctness hold: interaction groups, tile overflow, GBSA and CustomGB cutoffs, ConstantPotentialForce
# and Ewald. (diag3 ran the bitwise MD check; its ctest step found no ctest on PATH.)
D=/tmp/openmm-metal-bench/ultra-nblist
export PATH=/tmp/openmm-metal-bench/env/bin:$PATH
echo "== ctest NB_GATE=1"
NB_GATE=1 ctest --test-dir $D/t5/build -R '^TestMetal(NonbondedForce|CustomNonbondedForce|GBSAOBCForce|CustomGBForce|ConstantPotentialForce|Ewald)(Single|Mixed)$' \
    -j2 --timeout 600 --output-on-failure > $D/diag3b-ctest.txt 2>&1
grep -E "tests passed|\*\*\*|Passed|Failed" $D/diag3b-ctest.txt | cut -c1-120
echo "== DIAG3B DONE"

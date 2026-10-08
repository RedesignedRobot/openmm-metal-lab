#!/bin/sh
# nblist: correctness of the NB_GATE knob on the dev2 tree (t5), inside one lease.sh --correctness hold.
# Bitwise gate-on vs gate-off MD on rf (short-list sort), apoa1rf (bucket sort, large blocks) and pme,
# then the nblist-related ctests with NB_GATE=1: interaction groups, tile overflow, GBSA and CustomGB
# cutoffs, ConstantPotentialForce and Ewald.
D=/tmp/openmm-metal-bench/ultra-nblist
B=/tmp/openmm-metal-bench/ultra-base
PY=$D/t5/venv/bin/python
echo "== gatecheck"
$PY $D/gatecheck.py $B/benchmarks rf,apoa1rf,pme 2>&1 | grep -v "^$"
echo "== ctest NB_GATE=1"
NB_GATE=1 ctest --test-dir $D/t5/build -R '^TestMetal(NonbondedForce|CustomNonbondedForce|GBSAOBCForce|CustomGBForce|ConstantPotentialForce|Ewald)(Single|Mixed)$' \
    -j2 --timeout 600 --output-on-failure > $D/diag3-ctest.txt 2>&1
grep -E "tests passed|\*\*\*|Passed|Failed" $D/diag3-ctest.txt | cut -c1-120
echo "== DIAG3 DONE"

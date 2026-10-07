#!/bin/sh
# nblist: correctness of NB_GATE=2 (findBlocks through an indirect dispatch, zero threadgroups when no
# rebuild) on tree t6, inside one lease.sh --correctness hold. Bitwise gate-2 vs gate-off MD on rf and
# apoa1rf, then forces against Reference with NB_GATE=2.
D=/tmp/openmm-metal-bench/ultra-nblist
B=/tmp/openmm-metal-bench/ultra-base
F=/tmp/openmm-metal-bench/ultra-tools/forces.py
PY=$D/t6/venv/bin/python
mkdir -p $D/diag4
echo "== gatecheck gate 2"
$PY $D/gatecheck.py $B/benchmarks rf,apoa1rf 2 2>&1 | grep -v "^$"
echo "== forces g2"
NB_GATE=2 $PY $F $B/benchmarks $D/diag4/forces-g2.txt $B/forces.txt | grep -E "FAIL|PASS|ok$" | cut -c1-110
echo "== DIAG4 DONE"

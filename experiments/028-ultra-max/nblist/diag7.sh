#!/bin/sh
# nblist: diag6 showed the rf single MAX_BITS 0 md100 outlier (atom 14426, 1.5) in fresh MAX_BITS 0 and 4
# contexts alike. mdstraddle.py tests whether it is a pair on the cutoff that float and double r2 split.
D=/tmp/openmm-metal-bench/ultra-nblist
B=/tmp/openmm-metal-bench/ultra-base
$D/t5/venv/bin/python $D/mdstraddle.py $B/benchmarks rf,pme NB_MAXBITS=0
$D/t5/venv/bin/python $D/mdstraddle.py $B/benchmarks rf,pme
echo "== DIAG7 DONE"

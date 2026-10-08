#!/bin/sh
# nblist: why does forces.py --md 100 flag MAX_BITS 0 on rf single and the dev2 default on pme single?
# mdfresh.py separates a stale list from arithmetic; pme's cand2 build is the control for the pme row.
D=/tmp/openmm-metal-bench/ultra-nblist
B=/tmp/openmm-metal-bench/ultra-base
echo "== mdfresh t5 default"
$D/t5/venv/bin/python $D/mdfresh.py $B/benchmarks rf,pme
echo "== mdfresh t5 NB_MAXBITS=0"
$D/t5/venv/bin/python $D/mdfresh.py $B/benchmarks rf,pme NB_MAXBITS=0
echo "== md100 cand2 (pme's frozen build, read-only)"
mkdir -p $D/diag6
/tmp/openmm-metal-bench/ultra-pme/cand2/venv/bin/python /tmp/openmm-metal-bench/ultra-tools/forces.py --md 100 $B/benchmarks $D/diag6/md100-cand2.txt $B/forces-md100.txt
echo "== DIAG6 DONE"

#!/bin/sh
# Mixed lane pass 5: c5 screen against c4 (2 x 15 s), then NVE drift of the c1-c5 stack (base runs are in pass 1).
M=/tmp/openmm-metal-bench/ultra-mixed
B=/tmp/openmm-metal-bench/ultra-base/venv/bin/python
echo "$(date -u +%H:%M:%SZ) pass 5 start"
[ -f $M/t5/BUILT ] || { echo "t5 is not built"; exit 1; }
/tmp/openmm-metal-bench/ultra-tools/ab.sh $M/screen5 2 15 gbsa,pme,apoa1pme \
    c4=$M/t4/venv/bin/python:Metal:mixed c5=$M/t5/venv/bin/python:Metal:mixed
/bin/sh $M/drift-run.sh $M/drift5-verlet.jsonl 50 verlet stack5=$M/t5/venv/bin/python
/bin/sh $M/drift-run.sh $M/drift5-vv.jsonl 50 vv stack5=$M/t5/venv/bin/python
echo "$(date -u +%H:%M:%SZ) pass 5 done"

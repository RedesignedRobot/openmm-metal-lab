#!/bin/sh
# fbb on ultra/integrated 6f6320bcd (r2/accum-nb-fbb-int c620a8e41, tree p) checks, then the large-system indirect
# rebuild (r2/accum-nb-irl-int 3b191bc96, tree q) build and checks, the sortedBlocks identity test, then a 3x30
# screen of both against ultra-integrated.
set -u
cd /tmp/openmm-metal-bench
W=$HOME/code/wt/r2-accum-nb
P=/tmp/openmm-metal-bench/ultra-r2-accum-nb-p
Q=/tmp/openmm-metal-bench/ultra-r2-accum-nb-q
O=/tmp/openmm-metal-bench/ultra-r2-accum-nb/nt
I=/tmp/openmm-metal-bench/ultra-r2-accum-nb/irl
mkdir -p $O $I
git -C $W checkout -q c620a8e41 && ./ultra-tools/sync.sh $W $P > $O/sync.out 2>&1 || { echo "sync p failed"; exit 1; }
git -C $W checkout -q r2/accum-nb-irl-int && ./ultra-tools/sync.sh $W $Q > $I/sync.out 2>&1 || { echo "sync q failed"; exit 1; }
./ultra-tools/build.sh $P > $O/build.out 2>&1 || { echo "build p failed"; exit 1; }
echo "build p ok"
./ultra-tools/lease.sh --correctness r2-accum-nb "fbb-nt detforces" $P/venv/bin/python ultra-tools/detforces.py ultra-base/benchmarks $O/detforces.txt > $O/detforces.out 2>&1; echo "p detforces exit $?"
LISTCHECK_LANE=r2-accum-nb ./ultra-tools/listcheck.sh $P $O/listcheck > $O/listcheck.out 2>&1; echo "p listcheck exit $?"
./ultra-tools/build.sh $Q > $I/build.out 2>&1 || { echo "build q failed"; exit 1; }
echo "build q ok"
./ultra-tools/lease.sh --correctness r2-accum-nb "irl detforces" $Q/venv/bin/python ultra-tools/detforces.py ultra-base/benchmarks $I/detforces.txt > $I/detforces.out 2>&1; echo "q detforces exit $?"
LISTCHECK_LANE=r2-accum-nb ./ultra-tools/listcheck.sh $Q $I/listcheck > $I/listcheck.out 2>&1; echo "q listcheck exit $?"
# sortedBlocks identity: the same seeded 100-step trajectory in both trees must give bitwise identical forces.
T=apoa1rf,amber20-cellulose,amber20-stmv
./ultra-tools/lease.sh --correctness r2-accum-nb "fbb-nt md100 dump" $P/venv/bin/python /tmp/openmm-metal-bench/ultra-r2-accum-nb/chk/dumpf.py dump $I/p-md100.npz single $T 100 > $I/p-dump.out 2>&1; echo "p dump exit $?"
./ultra-tools/lease.sh --correctness r2-accum-nb "irl md100 dump" $Q/venv/bin/python /tmp/openmm-metal-bench/ultra-r2-accum-nb/chk/dumpf.py dump $I/q-md100.npz single $T 100 > $I/q-dump.out 2>&1; echo "q dump exit $?"
/tmp/openmm-metal-bench/env/bin/python3 -c "
import numpy as np, sys
a, b = np.load('$I/p-md100.npz'), np.load('$I/q-md100.npz')
for k in a.files:
    print(k, 'identical' if np.array_equal(a[k], b[k]) else 'DIFFERENT max %.3e' % np.abs(a[k]-b[k]).max())
" > $I/identity.txt 2>&1; cat $I/identity.txt
./ultra-tools/ab.sh $I/ab 3 30 rf,pme,apoa1rf,apoa1pme,amber20-stmv int_s=/tmp/openmm-metal-bench/ultra-integrated/venv/bin/python:Metal:single fbb_s=$P/venv/bin/python:Metal:single irl_s=$Q/venv/bin/python:Metal:single int_m=/tmp/openmm-metal-bench/ultra-integrated/venv/bin/python:Metal:mixed fbb_m=$P/venv/bin/python:Metal:mixed irl_m=$Q/venv/bin/python:Metal:mixed > $I/ab.out 2>&1; echo "ab exit $?"
echo day done

#!/bin/sh
# sortedBlocks identity with DeterministicForces: the same seeded 100-step run in trees p and q must be bitwise equal.
set -u
cd /tmp/openmm-metal-bench
I=/tmp/openmm-metal-bench/ultra-r2-accum-nb/irl
D=/tmp/openmm-metal-bench/ultra-r2-accum-nb/chk/dumpf.py
T=apoa1rf,amber20-cellulose,amber20-stmv
for tree in p q; do
    ./ultra-tools/lease.sh --correctness r2-accum-nb "$tree det md100 dump" /tmp/openmm-metal-bench/ultra-r2-accum-nb-$tree/venv/bin/python $D dump $I/$tree-det.npz single+det $T 100 > $I/$tree-det.out 2>&1; echo "$tree det dump exit $?"
done
/tmp/openmm-metal-bench/env/bin/python3 -c "
import numpy as np
a, b = np.load('$I/p-det.npz'), np.load('$I/q-det.npz')
for k in a.files:
    print(k, 'identical' if np.array_equal(a[k], b[k]) else 'DIFFERENT max %.3e' % np.abs(a[k]-b[k]).max())
" > $I/identity-det.txt 2>&1; cat $I/identity-det.txt
./ultra-r2-accum-nb/chk/screen.sh

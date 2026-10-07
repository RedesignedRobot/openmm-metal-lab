#!/bin/sh
# nblist: forces against Reference after 100 MD steps for the gate candidates (the rebuild trigger moved
# into findBlockBounds), inside one lease.sh --correctness hold. ultra-base/forces-md100.txt is the
# baseline, and e342bc02f runs as the control. t7 = ca1b8f595, t8 = 2073479ee.
D=/tmp/openmm-metal-bench/ultra-nblist
B=/tmp/openmm-metal-bench/ultra-base
F=/tmp/openmm-metal-bench/ultra-tools/forces.py
mkdir -p $D/diag5
for t in e342 t7 t8; do
    if [ $t = e342 ]; then PY=$D/venv/bin/python; else PY=$D/$t/venv/bin/python; fi
    echo "== md100 $t"
    $PY $F --md 100 $B/benchmarks $D/diag5/md100-$t.txt $B/forces-md100.txt > /dev/null 2>&1; echo "exit $?"
    cat $D/diag5/md100-$t.txt
done
echo "== DIAG5 DONE"

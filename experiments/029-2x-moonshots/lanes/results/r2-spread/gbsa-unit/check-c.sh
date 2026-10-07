#!/bin/sh
# gbfold-c correctness: forces and md100 against base, GBSAOBC ctests, bitwise DeterministicForces, and gbsa NVE
# drift (verlet, 2 fs, 100 ps, tol 1e-8) for seeds 1-4 against trunk 5071882fa (ultra-r2-fah-trunk).
export PATH=/tmp/openmm-metal-bench/env/bin:$PATH
unset PYTHONPATH
T=/tmp/openmm-metal-bench/ultra-tools
D=/tmp/openmm-metal-bench/ultra-r3-gbfold-c
TR=/tmp/openmm-metal-bench/ultra-r2-fah-trunk
B=/tmp/openmm-metal-bench/ultra-base
O=$D/check
mkdir -p $O
cd $D
echo "== forces"; $D/venv/bin/python $T/forces.py $B/benchmarks $O/forces.txt $B/forces.txt; echo "forces exit=$?"
echo "== md100"; $D/venv/bin/python $T/forces.py --md 100 $B/benchmarks $O/md100.txt $B/forces-md100.txt; echo "md100 exit=$?"
echo "== ctest"; ctest --test-dir $D/build -j2 --timeout 600 --output-on-failure -R '^TestMetalGBSAOBCForce(Single|Mixed)$' > $O/ctest.txt 2>&1; echo "ctest exit=$?"; tail -3 $O/ctest.txt
echo "== detforces"; $D/venv/bin/python $T/detforces.py $B/benchmarks $O/det.txt; echo "detforces exit=$?"
for p in single mixed; do
    for s in 1 2 3 4; do
        echo "cand $p seed $s drift $($D/venv/bin/python /tmp/openmm-metal-bench/ultra-r2-mixed/drift.py $B/benchmarks gbsa $p 100 $s 1e-8 verlet)"
        echo "trunk $p seed $s drift $($TR/venv/bin/python /tmp/openmm-metal-bench/ultra-r2-mixed/drift.py $B/benchmarks gbsa $p 100 $s 1e-8 verlet)"
    done
done

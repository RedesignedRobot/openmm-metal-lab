#!/bin/sh
# r2-pmefft correctness: md100 forces against base, DeterministicForces bitwise, and the PME users' ctests.
export PATH=/tmp/openmm-metal-bench/env/bin:$PATH
unset PYTHONPATH
T=/tmp/openmm-metal-bench/ultra-tools
D=/tmp/openmm-metal-bench/ultra-r2-pmefft
B=/tmp/openmm-metal-bench/ultra-base
O=$D/check
mkdir -p $O
cd $D
echo "== md100"; $D/venv/bin/python $T/forces.py --md 100 $B/benchmarks $O/md100.txt $B/forces-md100.txt; echo "md100 exit=$?"
echo "== detforces"; $D/venv/bin/python $T/detforces.py $B/benchmarks $O/det.txt; echo "detforces exit=$?"
echo "== ctest"; ctest --test-dir $D/build -j2 --timeout 600 --output-on-failure -R '^TestMetal(NonbondedForce|Ewald|ConstantPotentialForce|AmoebaMultipoleForce|HippoNonbondedForce|DispersionPME)(Single|Mixed)$' > $O/ctest.txt 2>&1; echo "ctest exit=$?"; tail -15 $O/ctest.txt

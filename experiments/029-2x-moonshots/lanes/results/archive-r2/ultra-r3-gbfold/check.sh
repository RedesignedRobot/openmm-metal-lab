#!/bin/sh
# gbsa unit correctness per variant: forces and md100 against base, and the GBSAOBC ctests.
export PATH=/tmp/openmm-metal-bench/env/bin:$PATH
unset PYTHONPATH
T=/tmp/openmm-metal-bench/ultra-tools
D=/tmp/openmm-metal-bench/ultra-r3-gbfold
B=/tmp/openmm-metal-bench/ultra-base
cd $D
for v in trunk lanes32 fold; do
    O=$D/check/$v
    mkdir -p $O
    export OPENMM_METAL_GB_VARIANT=$v
    echo "== $v forces"; $D/venv/bin/python $T/forces.py $B/benchmarks $O/forces.txt $B/forces.txt; echo "$v forces exit=$?"
    echo "== $v md100"; $D/venv/bin/python $T/forces.py --md 100 $B/benchmarks $O/md100.txt $B/forces-md100.txt; echo "$v md100 exit=$?"
    echo "== $v ctest"; ctest --test-dir $D/build -j2 --timeout 600 --output-on-failure -R '^TestMetalGBSAOBCForce(Single|Mixed)$' > $O/ctest.txt 2>&1; echo "$v ctest exit=$?"; tail -4 $O/ctest.txt
done

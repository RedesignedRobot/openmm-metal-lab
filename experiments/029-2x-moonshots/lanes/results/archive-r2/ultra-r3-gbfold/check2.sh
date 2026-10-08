#!/bin/sh
# gbsa unit: bitwise DeterministicForces and gbsa NVE drift (verlet, 100 ps, tol 1e-8) per variant.
export PATH=/tmp/openmm-metal-bench/env/bin:$PATH
unset PYTHONPATH
T=/tmp/openmm-metal-bench/ultra-tools
D=/tmp/openmm-metal-bench/ultra-r3-gbfold
B=/tmp/openmm-metal-bench/ultra-base
cd $D
for v in trunk lanes32 fold; do
    O=$D/check/$v
    export OPENMM_METAL_GB_VARIANT=$v
    echo "== $v detforces"; $D/venv/bin/python $T/detforces.py $B/benchmarks $O/det.txt; echo "$v detforces exit=$?"
    for p in single mixed; do
        for s in 1 2; do
            echo "$v $p seed $s drift $($D/venv/bin/python /tmp/openmm-metal-bench/ultra-r2-mixed/drift.py $B/benchmarks gbsa $p 100 $s 1e-8 verlet)"
        done
    done
done

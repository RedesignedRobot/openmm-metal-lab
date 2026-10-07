#!/bin/sh
# 028 nonbonded lane: Ultra calibration for the M2 atomics probe, as force evaluations. nox 626652d2c has wrong forces,
# so benchmark.py's dynamics fail (ab-nox: NO RESULT); forcetime.py steps VerletIntegrator(1e-9 ps), where nothing moves.
# tiles 6d72c3ae9, xres 761d5a666, nox 626652d2c on apoa1rf single, 300 evals x 5, 2 rounds, order reversed in round 2.
# Run it under lease.sh as one timing ticket.
D=/tmp/openmm-metal-bench/ultra-nonbonded
unset PYTHONPATH
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
grep -q 6d72c3ae9 $D/BUILT && grep -q 761d5a666 $D-xres/BUILT && grep -q 626652d2c $D-nox/BUILT || { echo "a build is not ready, skipping"; exit 1; }
for round in 1 2; do
    arms="tiles xres nox"; [ $round = 2 ] && arms="nox xres tiles"
    for a in $arms; do
        case $a in tiles) dir=$D;; xres) dir=$D-xres;; nox) dir=$D-nox;; esac
        echo "$(date -u +%H:%M:%SZ) round $round $a load $(sysctl -n vm.loadavg)"
        (cd /tmp/openmm-metal-bench/ultra-base/benchmarks && $dir/venv/bin/python $D/forcetime.py apoa1rf single 300 5)
    done
done

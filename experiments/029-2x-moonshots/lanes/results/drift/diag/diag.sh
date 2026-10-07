#!/bin/sh
# Drift diagnosis after mixed seed 1 on ultra-r1 drifted +0.208 kJ/mol/ps. Seed 1, 20 ps equil, short NVE.
# usage: diag.sh metal | cpu
unset PYTHONPATH
cd /
case "$1" in
metal)
    /tmp/openmm-metal-bench/ultra-r1/venv/bin/python $HOME/code/metal/lab/experiments/029-2x-moonshots/lanes/results/drift/dhfr-nve.py /tmp/openmm-metal-bench/ultra-base/benchmarks/5dfr_solv-cube_equil.pdb Metal mixed 1 20 0.2 $HOME/code/metal/lab/experiments/029-2x-moonshots/lanes/results/drift/diag/r1-mixed-tol1e-5 1e-5
    /tmp/openmm-metal-bench/ultra-r1/venv/bin/python $HOME/code/metal/lab/experiments/029-2x-moonshots/lanes/results/drift/dhfr-nve.py /tmp/openmm-metal-bench/ultra-base/benchmarks/5dfr_solv-cube_equil.pdb Metal mixed 1 20 0.2 $HOME/code/metal/lab/experiments/029-2x-moonshots/lanes/results/drift/diag/r1-mixed-tol1e-8 1e-8
    /tmp/openmm-metal-bench/ultra-base/venv/bin/python $HOME/code/metal/lab/experiments/029-2x-moonshots/lanes/results/drift/dhfr-nve.py /tmp/openmm-metal-bench/ultra-base/benchmarks/5dfr_solv-cube_equil.pdb Metal mixed 1 20 0.2 $HOME/code/metal/lab/experiments/029-2x-moonshots/lanes/results/drift/diag/base-mixed-tol1e-5 1e-5 ;;
cpu)
    /tmp/openmm-metal-bench/ultra-r1/venv/bin/python $HOME/code/metal/lab/experiments/029-2x-moonshots/lanes/results/drift/dhfr-nve.py /tmp/openmm-metal-bench/ultra-base/benchmarks/5dfr_solv-cube_equil.pdb CPU mixed 1 10 0.1 $HOME/code/metal/lab/experiments/029-2x-moonshots/lanes/results/drift/diag/r1-cpu-tol1e-5 1e-5 ;;
esac
echo "DIAG $1 DONE $(date -u +%H:%M:%SZ)"

#!/bin/sh
# Runs on the M3 Ultra: the benchmark.py blocks of the profiler lane, through ultra-tools/ab.sh (lease per round and test).
# stmv: Metal single, Metal mixed, OpenCL single, 3 x 30 s. AMOEBA: OpenCL single, 2 x 30 s.
# Probes: the profiling build with its knobs off and with the nonbonded launch shape changed, against ultra-base, 2 x 15 s.
set -u
B=/tmp/openmm-metal-bench/ultra-base/venv/bin/python
P=/tmp/openmm-metal-bench/ultra-profiler/venv/bin/python
T=/tmp/openmm-metal-bench/ultra-tools
O=/tmp/openmm-metal-bench/ultra-profiler
$T/ab.sh $O/stmv 3 30 amber20-stmv metal=$B:Metal:single mixed=$B:Metal:mixed opencl=$B:OpenCL:single > $O/stmv.out 2>&1
$T/ab.sh $O/amoeba 2 30 amoebagk,amoebapme opencl=$B:OpenCL:single > $O/amoeba.out 2>&1
$T/ab.sh $O/probes 2 15 gbsa,rf,pme,apoa1pme base=$B:Metal:single prof=$P:Metal:single \
    nb6x256=$P:Metal:single:HD_NB_BLOCKS=6,HD_NB_TG=256 nb20x64=$P:Metal:single:HD_NB_BLOCKS=20 \
    nb80x64=$P:Metal:single:HD_NB_BLOCKS=80 tbpc24=$P:Metal:single:HD_TBPC=24 > $O/probes.out 2>&1
echo "queue done $(date -u +%H:%M:%SZ)"

#!/bin/sh
# Runs on the M3 Ultra: after the stmv ab.sh run ends, AMOEBA on OpenCL and the launch-shape probes (trimmed set).
set -u
B=/tmp/openmm-metal-bench/ultra-base/venv/bin/python
P=/tmp/openmm-metal-bench/ultra-profiler/venv/bin/python
T=/tmp/openmm-metal-bench/ultra-tools
O=/tmp/openmm-metal-bench/ultra-profiler
while pgrep -f "ab.sh $O/stmv " > /dev/null; do sleep 5; done
$T/ab.sh $O/amoeba 2 30 amoebagk,amoebapme opencl=$B:OpenCL:single > $O/amoeba.out 2>&1
$T/ab.sh $O/probes 2 15 gbsa,rf,pme,apoa1pme base=$B:Metal:single prof=$P:Metal:single \
    nb6x256=$P:Metal:single:HD_NB_BLOCKS=6,HD_NB_TG=256 tbpc24=$P:Metal:single:HD_TBPC=24 > $O/probes.out 2>&1
echo "queue done $(date -u +%H:%M:%SZ)"

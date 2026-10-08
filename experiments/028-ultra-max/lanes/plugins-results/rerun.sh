#!/bin/sh
# Runs on the M3 Ultra under one lease.sh hold: reruns the gate failures once on both trees, then
# times AMOEBA. The generalized Kirkwood candidate only changes amoebaGk.cc, so it runs on amoebagk only.
[ "$(ps -o nice= -p $$ | tr -d ' ')" = 0 ] || { echo "refusing to run at nice $(ps -o nice= -p $$)"; exit 1; }
L=/tmp/openmm-metal-bench/ultra-plugins
B=/tmp/openmm-metal-bench/ultra-base
T=/tmp/openmm-metal-bench/ultra-tools
echo "== plugins $(date -u +%H:%M:%SZ)"
ctest --test-dir $L/build -R '^(TestMetalGayBerneForceSingle|TestMetalLangevinMiddleIntegratorSingle|TestMetalAmoebaGeneralizedKirkwoodForceSingle|TestOpenCLAmoebaGeneralizedKirkwoodForceSingle)$' --timeout 300 2>&1 | grep -E "Test +#|exception|norms"
echo "== cand"
ctest --test-dir $L/cand/build -R '^TestMetalAmoebaGeneralizedKirkwoodForceSingle$' --timeout 300 2>&1 | grep -E "Test +#|exception|norms"
echo "== base"
ctest --test-dir $B/build -R '^(TestMetalGayBerneForceSingle|TestMetalLangevinMiddleIntegratorSingle|TestOpenCLAmoebaGeneralizedKirkwoodForceSingle)$' --timeout 300 2>&1 | grep -E "Test +#|exception|norms"
echo "rerun done $(date -u +%H:%M:%SZ)"
$T/ab.sh $L/amoeba-gk 3 30 amoebagk \
    metal-single=$L/venv/bin/python:Metal:single cand-single=$L/cand/venv/bin/python:Metal:single \
    metal-mixed=$L/venv/bin/python:Metal:mixed cand-mixed=$L/cand/venv/bin/python:Metal:mixed \
    opencl-single=$L/venv/bin/python:OpenCL:single
$T/ab.sh $L/amoeba-pme 3 30 amoebapme \
    metal-single=$L/venv/bin/python:Metal:single metal-mixed=$L/venv/bin/python:Metal:mixed \
    opencl-single=$L/venv/bin/python:OpenCL:single
echo "all done $(date -u +%H:%M:%SZ)"

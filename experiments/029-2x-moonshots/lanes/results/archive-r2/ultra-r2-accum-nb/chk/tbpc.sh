#!/bin/sh
# probe8: executeKernel grid cap (P_TBPC, probe-only getenv) on the large tests. Build tree p, then one 2x15 screen.
set -eu
cd /tmp/openmm-metal-bench
./ultra-tools/build.sh /tmp/openmm-metal-bench/ultra-r2-accum-nb-p > ultra-r2-accum-nb/build-tbpc.out 2>&1
grep -q P_TBPC ultra-r2-accum-nb-p/src/platforms/metal/src/MetalContext.cpp
C=/tmp/openmm-metal-bench/ultra-r2-accum-nb/venv/bin/python
P=/tmp/openmm-metal-bench/ultra-r2-accum-nb-p/venv/bin/python
exec ./ultra-tools/ab.sh /tmp/openmm-metal-bench/ultra-r2-accum-nb/probe8 2 15 apoa1pme,amber20-cellulose,amber20-stmv cand_s=$C:Metal:single t24_s=$P:Metal:single:P_TBPC=24 t48_s=$P:Metal:single:P_TBPC=48 t96_s=$P:Metal:single:P_TBPC=96

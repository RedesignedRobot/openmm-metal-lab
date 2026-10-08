#!/bin/sh
# Runs on the M3 Ultra under lease.sh --correctness: the Metal AMOEBA GK test on the prec experiment build
# (86d559ebb) with precise rsqrt, then precise recip, in one AMOEBA program at a time, to find which
# program's fast math causes the villin miss.
[ "$(ps -o nice= -p $$ | tr -d ' ')" = 0 ] || { echo "refusing to run at nice $(ps -o nice= -p $$)"; exit 1; }
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
L=/tmp/openmm-metal-bench/ultra-plugins
mkdir -p $L/villin && cd $L/villin || exit 1
for fn in rsqrt recip; do
    for kernel in computeLabFrameMoments computeFixedField computeInducedField computeElectrostatics computeBornSum computeWCAForce; do
        OPENMM_METAL_PRECISE=$fn OPENMM_METAL_PRECISE_KERNEL=$kernel $L/prec/build/TestMetalAmoebaGeneralizedKirkwoodForce single > out.txt 2>&1
        status=$?
        echo "precise=$fn kernel=$kernel exit $status: $(grep -E 'Done|norms|exception' out.txt | head -1)"
    done
done
echo "villinkern done $(date -u +%H:%M:%SZ)"

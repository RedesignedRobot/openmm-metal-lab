#!/bin/sh
# Runs on the M3 Ultra under lease.sh --correctness: the four AMOEBA tests that fail to compile on
# integrated e08a0b1c6, on cand (6aac90ee3 = e08a0b1c6 plus bb813dadc), each alone.
[ "$(ps -o nice= -p $$ | tr -d ' ')" = 0 ] || { echo "refusing to run at nice $(ps -o nice= -p $$)"; exit 1; }
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
L=/tmp/openmm-metal-bench/ultra-plugins
cd $L/cand/build || exit 1
echo "cand $(sed -n 's/^commit //p' $L/cand/BUILT) $(date -u +%H:%M:%SZ)"
/tmp/openmm-metal-bench/env/bin/ctest -R '^TestMetalAmoeba(ExtrapolatedPolarization|MultipoleForce)(Single|Mixed)$' --output-on-failure 2>&1 | grep -E "Test +#|tests passed|exception|error" 
echo "pmefix done $(date -u +%H:%M:%SZ)"

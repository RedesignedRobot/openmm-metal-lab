#!/bin/sh
# Runs on the M3 Ultra under lease.sh --correctness: the Metal AMOEBA GK test on the prec experiment build,
# once per OPENMM_METAL_PRECISE setting, to find which fast function causes the villin miss.
[ "$(ps -o nice= -p $$ | tr -d ' ')" = 0 ] || { echo "refusing to run at nice $(ps -o nice= -p $$)"; exit 1; }
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
L=/tmp/openmm-metal-bench/ultra-plugins
mkdir -p $L/villin && cd $L/villin || exit 1
for setting in none exp rsqrt recip log pow exp,rsqrt,recip,log,pow; do
    if [ $setting = none ]; then unset OPENMM_METAL_PRECISE; else export OPENMM_METAL_PRECISE=$setting; fi
    $L/prec/build/TestMetalAmoebaGeneralizedKirkwoodForce single > out.txt 2>&1
    status=$?
    echo "precise=$setting exit $status: $(grep -E 'Done|norms|exception' out.txt | head -1)"
done
echo "villinmath done $(date -u +%H:%M:%SZ)"

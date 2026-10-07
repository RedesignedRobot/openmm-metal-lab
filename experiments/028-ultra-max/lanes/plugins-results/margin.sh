#!/bin/sh
# Runs on the M3 Ultra under lease.sh --correctness: the GK test on prec (1f29eafe1, which prints the force
# norm margin of every GK comparison) for 6998abf2f's math (none), precise rsqrt in the fixed field
# (95373278b), precise divide there, and both there; Metal single and mixed, plus OpenCL single for scale.
[ "$(ps -o nice= -p $$ | tr -d ' ')" = 0 ] || { echo "refusing to run at nice $(ps -o nice= -p $$)"; exit 1; }
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
L=/tmp/openmm-metal-bench/ultra-plugins
mkdir -p $L/margin && cd $L/margin || exit 1
unset OPENMM_METAL_PRECISE OPENMM_METAL_PRECISE_KERNEL
$L/prec/build/TestOpenCLAmoebaGeneralizedKirkwoodForce single > opencl-single.txt 2>&1
echo "opencl single exit $?"; grep -E "^margin .*Villin" opencl-single.txt
for precision in single mixed; do
    for fn in none rsqrt recip rsqrt,recip; do
        if [ $fn = none ]; then unset OPENMM_METAL_PRECISE OPENMM_METAL_PRECISE_KERNEL
        else export OPENMM_METAL_PRECISE=$fn OPENMM_METAL_PRECISE_KERNEL=computeFixedField; fi
        $L/prec/build/TestMetalAmoebaGeneralizedKirkwoodForce $precision > metal-$precision-$fn.txt 2>&1
        echo "metal $precision precise=$fn exit $?"; grep -E "^margin .*Villin" metal-$precision-$fn.txt
    done
done
echo "margin done $(date -u +%H:%M:%SZ)"

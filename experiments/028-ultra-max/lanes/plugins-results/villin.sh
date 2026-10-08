#!/bin/sh
# Runs on the M3 Ultra under lease.sh --correctness: the AMOEBA GK test (villin cases included) on
# ultra-base's OpenCL and on bar's Metal, run directly from a scratch dir so nothing lands in ultra-base.
[ "$(ps -o nice= -p $$ | tr -d ' ')" = 0 ] || { echo "refusing to run at nice $(ps -o nice= -p $$)"; exit 1; }
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
L=/tmp/openmm-metal-bench/ultra-plugins
B=/tmp/openmm-metal-bench/ultra-base
mkdir -p $L/villin && cd $L/villin || exit 1
run() {
    echo "== $1 $2 $(date -u +%H:%M:%SZ)"
    "$1" "$2" 2>&1 | tail -n 5
    echo "exit $? $1 $2"
}
run $B/build/TestOpenCLAmoebaGeneralizedKirkwoodForce single
run $B/build/TestOpenCLAmoebaGeneralizedKirkwoodForce mixed
run $L/bar/build/TestMetalAmoebaGeneralizedKirkwoodForce single
run $L/bar/build/TestMetalAmoebaGeneralizedKirkwoodForce mixed
echo "villin done $(date -u +%H:%M:%SZ)"

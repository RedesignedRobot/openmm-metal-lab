#!/bin/sh
# Builds two Metal plugins in build-b from src-b, with no install: 71a602b43 (plugins-b0), then 71a602b43 plus the
# bonded commit d8ab45b2b (plugins-bonded). Each arm is checked file by file against its git tree before it builds,
# and build-b's tests are left on the bonded arm.
set -eu
L=/tmp/openmm-metal-bench/ultra-atomics
S=$L/src-b
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
export PATH=/tmp/openmm-metal-bench/env/bin:$PATH
unset PYTHONPATH
T="OpenMMMetal TestMetalHarmonicBondForce TestMetalHarmonicAngleForce TestMetalPeriodicTorsionForce TestMetalRBTorsionForce TestMetalCustomBondForce TestMetalCustomAngleForce TestMetalCustomTorsionForce TestMetalCustomCompoundBondForce TestMetalCMAPTorsionForce TestMetalCustomExternalForce TestMetalConstantPotentialForce TestMetalNonbondedForce"
check() {
  cd $S
  cut -d' ' -f2- $1 | git hash-object --stdin-paths > $L/logs/hashes.txt
  cut -d' ' -f1 $1 | cmp -s - $L/logs/hashes.txt || { echo "src-b differs from $1"; exit 1; }
  find . -type f ! -path ./.commit | sed 's|^\./||' | sort > $L/logs/files.txt
  cut -d' ' -f2- $1 | sort | comm -13 - $L/logs/files.txt > $L/logs/extra.txt
  [ ! -s $L/logs/extra.txt ] || { echo "src-b has files outside $1:"; head $L/logs/extra.txt; exit 1; }
}
build() {
  nice -n 10 cmake $L/build-b > $L/logs/configure-b.log 2>&1
  targets=$(for t in $T; do grep -q "^build $t:\|^build [^:]*/$t:\|^build $t " $L/build-b/build.ninja && echo $t; done)
  nice -n 10 ninja -C $L/build-b -j6 $targets > $L/logs/build-b-$1.log 2>&1 || { grep -E "error|FAILED" $L/logs/build-b-$1.log | head -20; exit 1; }
  rm -rf $L/plugins-$1 && cp -R $L/prefix/lib/plugins $L/plugins-$1 && cp $L/build-b/libOpenMMMetal.dylib $L/plugins-$1/
  echo "$1 $(md5 -q $L/plugins-$1/libOpenMMMetal.dylib) foldForceWords=$(grep -ac foldForceWords $L/plugins-$1/libOpenMMMetal.dylib || true) bondedPad=$(grep -ac bondedPad $L/plugins-$1/libOpenMMMetal.dylib || true)"
}
cd $S && rm -f platforms/metal/src/kernels/forceWords.metal platforms/metal/src/MetalBondedUtilities.cpp && tar xmf $L/ov/base.tar
check $L/ov/man-b0.txt
build b0
cd $S && tar xmf $L/ov/bonded.tar
check $L/ov/man-bonded.txt
build bonded
echo bb done

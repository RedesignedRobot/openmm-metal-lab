#!/bin/sh
# Lab-only census plugins for the bonded screen: src-b (d8ab45b2b) copied to src-bp with the lane's profiler patch,
# built in build-bp as plugins-prof-bonded, then with the bonded files put back to 71a602b43 as plugins-prof-b0.
# Every file the patch does not touch is checked against the commit's git tree before each build.
set -eu
L=/tmp/openmm-metal-bench/ultra-atomics
S=$L/src-bp
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
export PATH=/tmp/openmm-metal-bench/env/bin:$PATH
unset PYTHONPATH
while [ -e /tmp/openmm-window ]; do sleep 30; done
PATCHED="platforms/metal/include/MetalQueue.h platforms/metal/src/MetalArray.cpp platforms/metal/src/MetalContext.cpp platforms/metal/src/MetalEvent.cpp platforms/metal/src/MetalFFT3D.cpp platforms/metal/src/MetalNonbondedUtilities.cpp platforms/metal/src/MetalQueue.cpp"
check() {
  cd $S
  printf "%s\n" $PATCHED > $L/logs/bp-patched.txt
  grep -v -F -f $L/logs/bp-patched.txt $1 > $L/logs/bp-man.txt
  cut -d' ' -f2- $L/logs/bp-man.txt | git hash-object --stdin-paths > $L/logs/bp-hashes.txt
  cut -d' ' -f1 $L/logs/bp-man.txt | cmp -s - $L/logs/bp-hashes.txt || { echo "src-bp differs from $1"; exit 1; }
}
build() {
  nice -n 10 cmake $L/build-bp > $L/logs/configure-bp.log 2>&1
  nice -n 10 ninja -C $L/build-bp -j6 OpenMMMetal > $L/logs/build-bp-$1.log 2>&1 || { grep -E "error|FAILED" $L/logs/build-bp-$1.log | head -20; exit 1; }
  rm -rf $L/plugins-$1 && cp -R $L/prefix/lib/plugins $L/plugins-$1 && cp $L/build-bp/libOpenMMMetal.dylib $L/plugins-$1/
  echo "$1 $(md5 -q $L/plugins-$1/libOpenMMMetal.dylib) bondedPad=$(grep -ac bondedPad $L/plugins-$1/libOpenMMMetal.dylib || true) gpuprof=$(grep -ac GPUPROF_OUT $L/plugins-$1/libOpenMMMetal.dylib || true)"
}
rm -rf $S && cp -R $L/src-b $S
cd $S && patch -s -p1 < $L/ov/prof.patch && rm -f platforms/metal/src/*.orig platforms/metal/include/*.orig && cp $L/ov/GpuProf.h platforms/metal/src/
check $L/ov/man-bonded.txt
[ -f $L/build-bp/build.ninja ] || nice -n 10 cmake -S $S -B $L/build-bp -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_INSTALL_PREFIX=$L/prefix-bp -DOPENMM_BUILD_METAL_LIB=ON -DOPENMM_BUILD_OPENCL_LIB=OFF \
  -DOPENMM_BUILD_PYTHON_WRAPPERS=OFF -DOPENMM_BUILD_C_AND_FORTRAN_WRAPPERS=OFF -DOPENMM_BUILD_EXAMPLES=OFF \
  -DBUILD_TESTING=OFF > $L/logs/configure-bp.log 2>&1
build prof-bonded
cd $S && rm -f platforms/metal/src/MetalBondedUtilities.cpp && tar xmf $L/ov/base.tar platforms/common/include/openmm/common/BondedUtilities.h platforms/metal/include/MetalBondedUtilities.h platforms/metal/tests/TestMetalHarmonicBondForce.cpp
check $L/ov/man-b0.txt
build prof-b0
echo bbp done

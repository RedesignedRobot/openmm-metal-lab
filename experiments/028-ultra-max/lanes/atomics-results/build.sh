#!/bin/sh
# Configure (once) and build the atomics lane tree on the Studio.
set -e
B=/tmp/openmm-metal-bench
L=$B/ultra-atomics
export PATH=$B/env/bin:$PATH
if [ ! -f $L/build/build.ninja ]; then
  cmake -S $L/src -B $L/build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_INSTALL_PREFIX=$L/prefix -DPYTHON_EXECUTABLE=$B/env/bin/python \
    -DOPENMM_BUILD_OPENCL_LIB=ON -DOPENMM_BUILD_METAL_LIB=ON -DOPENMM_BUILD_C_AND_FORTRAN_WRAPPERS=OFF \
    -DOPENMM_BUILD_EXAMPLES=OFF > $L/configure.log 2>&1
fi
ninja -C $L/build -j8 "$@" > $L/build.log 2>&1
echo BUILD_OK

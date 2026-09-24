#!/bin/sh
# Release build of 6df2b8bcb with Metal and OpenCL, no tests, Python module into the scratch env.
set -eu
B=/tmp/openmm-metal-bench
PATH=$B/env/bin:$PATH
cmake -S $B/src -B $B/build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_INSTALL_PREFIX=$B/prefix -DPYTHON_EXECUTABLE=$B/env/bin/python \
  -DOPENMM_BUILD_METAL_LIB=ON -DOPENMM_BUILD_OPENCL_LIB=ON -DOPENMM_BUILD_CUDA_LIB=OFF \
  -DOPENMM_BUILD_C_AND_FORTRAN_WRAPPERS=OFF -DBUILD_TESTING=OFF > $B/configure.log 2>&1
ninja -C $B/build -j8 > $B/ninja.log 2>&1
ninja -C $B/build install > $B/install.log 2>&1
ninja -C $B/build PythonInstall > $B/python.log 2>&1
echo built

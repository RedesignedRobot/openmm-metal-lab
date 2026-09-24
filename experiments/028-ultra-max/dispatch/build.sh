#!/bin/sh
# Runs on the M3 Ultra: configure, build and install the dispatch lane tree in <dir> (src/ inside it).
# The Python module is left in build/python/build/lib*; env.sh points PYTHONPATH and the library paths at it.
# usage: build.sh <dir>
set -eu
dir="$1"
export PATH=/tmp/openmm-metal-bench/env/bin:$PATH
[ -f "$dir/build/build.ninja" ] || cmake -S "$dir/src" -B "$dir/build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_INSTALL_PREFIX="$dir/prefix" \
    -DPYTHON_EXECUTABLE=/tmp/openmm-metal-bench/env/bin/python \
    -DOPENMM_BUILD_OPENCL_LIB=ON -DOPENMM_BUILD_METAL_LIB=ON \
    -DOPENMM_BUILD_C_AND_FORTRAN_WRAPPERS=OFF > "$dir/cmake.log" 2>&1
ninja -C "$dir/build" -j8 > "$dir/ninja.log" 2>&1 || { tail -40 "$dir/ninja.log"; exit 1; }
ninja -C "$dir/build" install > /dev/null
echo "built $dir"

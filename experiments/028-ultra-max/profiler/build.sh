#!/bin/sh
# Runs on the M3 Ultra: configure, build and install the profiling tree under /tmp/openmm-metal-bench/ultra-profiler.
# The venv has no other openmm, so setup.py can't touch the shared env. Xcode-beta toolchain, nice 10, -j6 (RULES.md).
# build-xb is a fresh build dir because the first build (build/) used the Command Line Tools SDK.
set -e
D=/tmp/openmm-metal-bench/ultra-profiler
export PATH=/tmp/openmm-metal-bench/env/bin:$PATH
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
export PIP_NO_CACHE_DIR=1
if [ ! -x "$D/venv/bin/python" ]; then
    /tmp/openmm-metal-bench/env/bin/python3 -m venv "$D/venv"
    "$D/venv/bin/python" -m pip -q install numpy cython setuptools
fi
cd "$D/src"
if [ ! -f build-xb/build.ninja ]; then
    cmake -S . -B build-xb -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_INSTALL_PREFIX="$D/prefix" -DPYTHON_EXECUTABLE="$D/venv/bin/python" \
        -DOPENMM_BUILD_OPENCL_LIB=ON -DOPENMM_BUILD_C_AND_FORTRAN_WRAPPERS=OFF > "$D/cmake.log" 2>&1
fi
grep -q "^CMAKE_OSX_SYSROOT:.*Xcode-beta" build-xb/CMakeCache.txt || { echo "build-xb is not on the Xcode-beta SDK"; exit 1; }
nice -n 10 ninja -C build-xb -j6 > "$D/build.log" 2>&1 || { grep -E "error|FAILED" "$D/build.log" | head -20; exit 1; }
nice -n 10 ninja -C build-xb -j6 install > /dev/null
nice -n 10 ninja -C build-xb -j6 PythonInstall > "$D/python.log" 2>&1
cd "$D"
"$D/venv/bin/python" -c "import openmm as m; print([m.Platform.getPlatform(i).getName() for i in range(m.Platform.getNumPlatforms())], m.__file__)"
echo "BUILD_DONE $(date -u +%H:%M:%SZ)"

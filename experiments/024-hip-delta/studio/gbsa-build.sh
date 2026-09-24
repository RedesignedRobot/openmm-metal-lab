#!/bin/sh
# Runs on the Studio: configure, build and install one tree under /tmp/openmm-metal-bench/gbsa-gap.
# The venv has no pip and sees only numpy, Cython and setuptools through pydeps, never the shared
# env's openmm, so setup.py can't remove it. No tests, no OpenCL.
# usage: gbsa-build.sh <tree>
set -e
D=/tmp/openmm-metal-bench/gbsa-gap
ENV=/tmp/openmm-metal-bench/env
SITE=$ENV/lib/python3.13/site-packages
export PATH=$ENV/bin:$PATH
export PYTHONPATH=$D/pydeps
tree="$1"
if [ ! -d "$D/pydeps" ]; then
    mkdir "$D/pydeps"
    for p in numpy Cython cython.py pyximport setuptools _distutils_hack; do ln -s "$SITE/$p" "$D/pydeps/$p"; done
fi
[ -x "$D/venv-$tree/bin/python" ] || $ENV/bin/python3 -m venv --without-pip "$D/venv-$tree"
cd "$D/$tree"
if [ ! -f build/build.ninja ]; then
    cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_INSTALL_PREFIX="$D/prefix-$tree" -DPYTHON_EXECUTABLE="$D/venv-$tree/bin/python" \
        -DBUILD_TESTING=OFF -DOPENMM_BUILD_OPENCL_LIB=OFF -DOPENMM_BUILD_EXAMPLES=OFF \
        -DOPENMM_BUILD_C_AND_FORTRAN_WRAPPERS=OFF > "$D/cmake-$tree.log" 2>&1
fi
ninja -C build -j16 > "$D/build-$tree.log" 2>&1 || { grep -E "error|FAILED" "$D/build-$tree.log" | head; exit 1; }
ninja -C build install > /dev/null
ninja -C build PythonInstall > "$D/python-$tree.log" 2>&1 || { tail -20 "$D/python-$tree.log"; exit 1; }
cd /
"$D/venv-$tree/bin/python" -c "import openmm; print(openmm.Platform.getPlatformByName('Metal').getName(), openmm.__file__)"

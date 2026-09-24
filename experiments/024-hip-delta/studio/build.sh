#!/bin/sh
# Runs on the Studio: configure, build and install one tree under /tmp/openmm-metal-bench/hipdelta.
# Each tree gets its own venv with no other openmm, so setup.py can't remove the shared one.
# usage: build.sh <tree>
set -e
D=/tmp/openmm-metal-bench/hipdelta
export PATH=/tmp/openmm-metal-bench/env/bin:$PATH
export PIP_NO_CACHE_DIR=1
tree="$1"
if [ ! -x "$D/venv-$tree/bin/python" ]; then
    /tmp/openmm-metal-bench/env/bin/python3 -m venv "$D/venv-$tree"
    "$D/venv-$tree/bin/python" -m pip -q install numpy cython setuptools
fi
cd "$D/$tree"
if [ ! -f build/build.ninja ]; then
    cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_INSTALL_PREFIX="$D/prefix-$tree" -DPYTHON_EXECUTABLE="$D/venv-$tree/bin/python" \
        -DOPENMM_BUILD_C_AND_FORTRAN_WRAPPERS=OFF > "$D/cmake-$tree.log" 2>&1
fi
ninja -C build -j12 > "$D/build-$tree.log" 2>&1 || { grep -E "error|FAILED" "$D/build-$tree.log" | head; exit 1; }
ninja -C build install > /dev/null
ninja -C build PythonInstall > "$D/python-$tree.log" 2>&1
"$D/venv-$tree/bin/python" -c "import openmm; print(openmm.Platform.getPlatformByName('Metal').getName(), openmm.__file__)"

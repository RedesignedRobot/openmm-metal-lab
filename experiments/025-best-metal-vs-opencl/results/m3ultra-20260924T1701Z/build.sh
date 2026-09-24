#!/bin/sh
# Runs on the Studio under /tmp/openmm-metal-bench/m3ab.
# usage: build.sh ref|p9074   052eaa85b or 9074c38f1, C++ only, the FlexibleBarostat test binary, configured like evwait's build
#        build.sh hd    6df2b8bcb with Metal and OpenCL and the Python module in its own venv, no tests
set -e
D=/tmp/openmm-metal-bench/m3ab
ENV=/tmp/openmm-metal-bench/env
SITE=$ENV/lib/python3.13/site-packages
export PATH=$ENV/bin:$PATH
case "$1" in
ref|p9074)
    cd "$D/$1"
    cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_INSTALL_PREFIX="$D/prefix-$1" -DOPENMM_BUILD_OPENCL_LIB=OFF -DOPENMM_BUILD_PYTHON_WRAPPERS=OFF \
        -DOPENMM_BUILD_C_AND_FORTRAN_WRAPPERS=OFF > "$D/logs/configure-$1.log" 2>&1
    ninja -C build -j14 TestMetalMonteCarloFlexibleBarostat > "$D/logs/build-$1.log" 2>&1 \
        || { grep -E "error|FAILED" "$D/logs/build-$1.log" | head; exit 1; }
    ;;
hd)
    # The venv has no pip and sees numpy, scipy, Cython and setuptools through pydeps, never the
    # shared env's openmm, so setup.py can't remove it. amber20-dhfr needs scipy.
    mkdir -p "$D/pydeps"
    for p in numpy scipy Cython cython.py pyximport setuptools _distutils_hack; do
        [ -e "$D/pydeps/$p" ] || ln -s "$SITE/$p" "$D/pydeps/$p"
    done
    export PYTHONPATH=$D/pydeps
    [ -x "$D/venv/bin/python" ] || "$ENV/bin/python3" -m venv --without-pip "$D/venv"
    cd "$D/hd"
    cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_INSTALL_PREFIX="$D/prefix-hd" -DPYTHON_EXECUTABLE="$D/venv/bin/python" \
        -DBUILD_TESTING=OFF -DOPENMM_BUILD_EXAMPLES=OFF -DOPENMM_BUILD_C_AND_FORTRAN_WRAPPERS=OFF \
        > "$D/logs/configure-hd.log" 2>&1
    grep -q "^OPENMM_BUILD_OPENCL_LIB:BOOL=ON" build/CMakeCache.txt || { echo "OpenCL not enabled"; exit 1; }
    grep -q "^OPENMM_BUILD_METAL_LIB:BOOL=ON" build/CMakeCache.txt || { echo "Metal not enabled"; exit 1; }
    ninja -C build -j14 > "$D/logs/build-hd.log" 2>&1 || { grep -E "error|FAILED" "$D/logs/build-hd.log" | head; exit 1; }
    ninja -C build install > "$D/logs/install-hd.log" 2>&1
    ninja -C build PythonInstall > "$D/logs/python-hd.log" 2>&1 || { tail -20 "$D/logs/python-hd.log"; exit 1; }
    cd /
    "$D/venv/bin/python" -c "import openmm; print(openmm.__file__, getattr(openmm.version, 'git_revision', None), [openmm.Platform.getPlatform(i).getName() for i in range(openmm.Platform.getNumPlatforms())])"
    ;;
*)
    echo "usage: build.sh ref|p9074|hd"; exit 2 ;;
esac

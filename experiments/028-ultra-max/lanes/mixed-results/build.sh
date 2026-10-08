#!/bin/sh
# Runs on the Studio. usage: build.sh <tree> <tests:on|off>
# Builds /tmp/openmm-metal-bench/ultra-mixed/<tree> into prefix-<tree> with the Python module in a venv
# that cannot import the shared env's openmm (setup.py deletes installs it can import).
set -e
T="$1"
D=/tmp/openmm-metal-bench/ultra-mixed
ENV=/tmp/openmm-metal-bench/env
SITE=$ENV/lib/python3.13/site-packages
export PATH=$ENV/bin:$PATH

TESTS="${2:-off}"
mkdir -p "$D/pydeps" "$D/logs"
for p in numpy scipy Cython cython.py pyximport setuptools _distutils_hack; do
    [ -e "$D/pydeps/$p" ] || ln -s "$SITE/$p" "$D/pydeps/$p"
done
export PYTHONPATH=$D/pydeps
[ -x "$D/venv-$T/bin/python" ] || "$ENV/bin/python3" -m venv --without-pip "$D/venv-$T"
"$D/venv-$T/bin/python" -c "import openmm, sys; sys.exit(0 if 'venv-$T' in openmm.__file__ else 1)" 2>/dev/null \
    || ! "$D/venv-$T/bin/python" -c "import openmm" 2>/dev/null || { echo "venv imports a foreign openmm"; exit 1; }
cd "$D/$T"
BT=OFF; [ "$TESTS" = on ] && BT=ON
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_INSTALL_PREFIX="$D/prefix-$T" -DPYTHON_EXECUTABLE="$D/venv-$T/bin/python" \
    -DBUILD_TESTING=$BT -DOPENMM_BUILD_EXAMPLES=OFF -DOPENMM_BUILD_C_AND_FORTRAN_WRAPPERS=OFF \
    > "$D/logs/configure-$T.log" 2>&1
grep -q "^OPENMM_BUILD_OPENCL_LIB:BOOL=ON" build/CMakeCache.txt || { echo "OpenCL not enabled"; exit 1; }
grep -q "^OPENMM_BUILD_METAL_LIB:BOOL=ON" build/CMakeCache.txt || { echo "Metal not enabled"; exit 1; }
ninja -C build -j8 > "$D/logs/build-$T.log" 2>&1 || { grep -E "error|FAILED" "$D/logs/build-$T.log" | head; exit 1; }
ninja -C build install > "$D/logs/install-$T.log" 2>&1
ninja -C build PythonInstall > "$D/logs/python-$T.log" 2>&1 || { tail -20 "$D/logs/python-$T.log"; exit 1; }
grep REMOVING "$D/logs/python-$T.log" | grep -qv "venv-$T" && { echo "setup.py removed an install"; exit 1; }
cd /
"$D/venv-$T/bin/python" -c "import openmm; print(openmm.__file__, [openmm.Platform.getPlatform(i).getName() for i in range(openmm.Platform.getNumPlatforms())])"

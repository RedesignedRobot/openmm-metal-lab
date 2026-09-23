#!/bin/sh
# Build branch metal-fah-readiness (C1) into /tmp/openmm-metal-bench/020, under the Studio lease.
set -e
B=/tmp/openmm-metal-bench/020
export PATH=/tmp/openmm-metal-bench/env/bin:$PATH
until mkdir /tmp/openmm-lease 2>/dev/null; do sleep 20; done
echo "fah-readiness $(date -u +%H:%MZ) build C1 in $B" > /tmp/openmm-lease/owner
trap 'rm -rf /tmp/openmm-lease' EXIT
cd $B/src
[ -f build/build.ninja ] || cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_INSTALL_PREFIX=$B/prefix -DPYTHON_EXECUTABLE=$B/venv/bin/python -DOPENMM_BUILD_OPENCL_LIB=OFF > $B/cmake-configure.log 2>&1
ninja -C build -j16 > $B/build.log 2>&1
ninja -C build install >> $B/build.log 2>&1
ninja -C build PythonInstall > $B/pythoninstall.log 2>&1
$B/venv/bin/python -c "import openmm as m; print(m.version.full_version, [m.Platform.getPlatform(i).getName() for i in range(m.Platform.getNumPlatforms())])"

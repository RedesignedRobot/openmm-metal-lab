#!/bin/sh
# Incremental rebuild of C1 after a source sync, then the Metal suite, under the Studio lease.
B=/tmp/openmm-metal-bench/020
export PATH=/tmp/openmm-metal-bench/env/bin:$PATH
until mkdir /tmp/openmm-lease 2>/dev/null; do sleep 20; done
echo "fah-readiness $(date -u +%H:%MZ) rebuild+ctest -R Metal in $B" > /tmp/openmm-lease/owner
trap 'rm -rf /tmp/openmm-lease' EXIT
cd $B/src
ninja -C build -j16 > $B/build.log 2>&1 && ninja -C build install >> $B/build.log 2>&1 && ninja -C build PythonInstall > $B/pythoninstall.log 2>&1 || { echo BUILD FAILED; tail -20 $B/build.log; exit 1; }
cd build
ctest -R Metal -j4 --timeout 1500 --output-on-failure > $B/ctest-metal.log 2>&1
tail -12 $B/ctest-metal.log

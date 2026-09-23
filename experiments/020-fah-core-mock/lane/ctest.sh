#!/bin/sh
# Run the Metal test suite (single and mixed) for the C1 build, under the Studio lease.
B=/tmp/openmm-metal-bench/020
export PATH=/tmp/openmm-metal-bench/env/bin:$PATH
until mkdir /tmp/openmm-lease 2>/dev/null; do sleep 20; done
echo "fah-readiness $(date -u +%H:%MZ) ctest -R Metal in $B" > /tmp/openmm-lease/owner
trap 'rm -rf /tmp/openmm-lease' EXIT
cd $B/src/build
ctest -R Metal -j4 --timeout 1500 --output-on-failure > $B/ctest-metal.log 2>&1
tail -15 $B/ctest-metal.log

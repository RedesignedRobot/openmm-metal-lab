#!/bin/sh
# Rerun the two barostat tests that failed once after the C1 follow-up, 3 times each, under the lease.
B=/tmp/openmm-metal-bench/020
export PATH=/tmp/openmm-metal-bench/env/bin:$PATH
until mkdir /tmp/openmm-lease 2>/dev/null; do sleep 20; done
echo "fah-readiness $(date -u +%H:%MZ) barostat test reruns in $B" > /tmp/openmm-lease/owner
cd $B/src/build
for i in 1 2 3; do ctest -R "TestMetalMonteCarlo(Anisotropic)?BarostatSingle" --output-on-failure 2>&1 | grep -E "Test +#|Expected"; done
rm -rf /tmp/openmm-lease

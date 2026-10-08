#!/bin/sh
# HarmonicBond tests from build-b after the 0315b09fd test fix.
cd /tmp/openmm-metal-bench/ultra-atomics/build-b && /tmp/openmm-metal-bench/env/bin/ctest -R TestMetalHarmonicBondForce --output-on-failure

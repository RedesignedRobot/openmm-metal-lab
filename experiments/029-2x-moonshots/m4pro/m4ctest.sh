#!/bin/sh
cd /tmp/openmm-metal-bench/ultra-integrated/build
export OPENMM_PLUGIN_DIR=/tmp/openmm-metal-bench/ultra-integrated/prefix/lib/plugins
pass=0; fail=0; start=$(date +%s)
for t in NonbondedForce CustomNonbondedForce Ewald FFT Sort GBSAOBCForce CustomGBForce HarmonicBondForce HarmonicAngleForce PeriodicTorsionForce CMAPTorsionForce Settle VirtualSites LangevinMiddleIntegrator LangevinIntegrator VerletIntegrator CustomIntegrator MonteCarloBarostat MixedPrecision LocalEnergyMinimizer CommandBatching MultipleForces Checkpoints DispersionPME GayBerneForce AmoebaMultipoleForce AmoebaGeneralizedKirkwoodForce DrudeForce Rpmd; do
  for p in single mixed; do
    t0=$(date +%s)
    if /opt/homebrew/bin/gtimeout 600 nice -n 10 ./TestMetal$t $p > /tmp/openmm-metal-bench/ctest-$t-$p.log 2>&1; then r=PASS; pass=$((pass+1)); else r=FAIL; fail=$((fail+1)); fi
    echo "$r $t $p $(( $(date +%s)-t0 ))s"
  done
done
echo "pass=$pass fail=$fail wall=$(( $(date +%s)-start ))s"

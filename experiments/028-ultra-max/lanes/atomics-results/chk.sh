#!/bin/sh
# Correctness hold: bonded-arm unit tests from build-b, then force dumps of plugins-b0 (71a602b43) and
# plugins-bonded (d8ab45b2b), compared bit for bit. Exits 1 on any failure.
L=/tmp/openmm-metal-bench/ultra-atomics
[ "$(ps -o nice= -p $$ | tr -d ' ')" = 0 ] || { echo "nice is not 0"; exit 1; }
cd $L/build-b || exit 1
/tmp/openmm-metal-bench/env/bin/ctest -R "TestMetal(HarmonicBond|HarmonicAngle|PeriodicTorsion|RBTorsion|CustomBond|CustomAngle|CustomTorsion|CustomCompoundBond|CMAPTorsion|CustomExternal|ConstantPotential|Nonbonded)Force" --output-on-failure > $L/chk-ctest.log 2>&1
rc=$?
tail -3 $L/chk-ctest.log
cd $L/src/examples/benchmarks || exit 1
for v in b0 bonded; do
  OPENMM_PLUGIN_DIR=$L/plugins-$v $L/venv/bin/python $L/dumpforces.py $L/forces-$v.npz > $L/dump-$v.log 2>&1 || { echo "dump $v FAILED"; tail -5 $L/dump-$v.log; exit 1; }
done
/tmp/openmm-metal-bench/ultra-base/venv/bin/python $L/cmpforces.py $L/forces-b0.npz $L/forces-bonded.npz | tee $L/chk-cmp.txt
[ $rc = 0 ] && ! grep -q "identical=False" $L/chk-cmp.txt

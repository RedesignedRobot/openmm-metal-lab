"""Dump reciprocal-space forces (group 1) for a benchmark system: fdump.py BENCH TEST PREC OUT.npy"""
import os, sys
import numpy as np
import openmm as mm
benchDir, testName, precision, out = sys.argv[1:5]
os.chdir(benchDir)
src = open(os.path.join(benchDir, 'benchmark.py')).read().split('# Parse the command line options.')[0]
ns = {'__file__': os.path.join(benchDir, 'benchmark.py'), '__name__': 'bench'}
exec(compile(src, 'benchmark.py', 'exec'), ns)
system, positions, params = ns['retrieveTestSystem'](testName)
for f in system.getForces():
    f.setForceGroup(0)
    if isinstance(f, mm.NonbondedForce):
        f.setReciprocalSpaceForceGroup(1)
context = mm.Context(system, mm.VerletIntegrator(0.001), mm.Platform.getPlatformByName('Metal'), {'Precision': precision})
context.setPositions(positions)
f = context.getState(getForces=True, groups={1}).getForces(asNumpy=True)._value
np.save(out, f)
print(testName, precision, 'saved', f.shape, float(np.abs(f).mean()))

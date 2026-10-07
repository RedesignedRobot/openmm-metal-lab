"""Forces with DeterministicForces=true at the starting positions, saved per test and precision.
usage: bitforces.py <bench dir> <out dir> <tests> [precisions]"""
import sys, os, numpy as np
bench, out, tests = sys.argv[1], sys.argv[2], sys.argv[3].split(',')
precs = sys.argv[4].split(',') if len(sys.argv) > 4 else ['single', 'mixed']
os.makedirs(out, exist_ok=True)
src = open(bench + '/benchmark.py').read()
g = {'__name__': 'bitforces'}
os.chdir(bench)
exec(compile(src[:src.index('def serializeTest')], bench + '/benchmark.py', 'exec'), g)
import openmm as mm
for test in tests:
    system, positions, _ = g['retrieveTestSystem'](test)
    for prec in precs:
        integ = mm.VerletIntegrator(0.001)
        c = mm.Context(system, integ, mm.Platform.getPlatformByName('Metal'), {'Precision': prec, 'DeterministicForces': 'true'})
        c.setPositions(positions)
        s = c.getState(getForces=True, getEnergy=True)
        f = s.getForces(asNumpy=True)._value
        e = s.getPotentialEnergy()._value
        s2 = c.getState(getForces=True)
        f2 = s2.getForces(asNumpy=True)._value
        np.savez(f'{out}/{test}-{prec}.npz', f=f, e=e, same=np.array_equal(f, f2))
        print(test, prec, 'E', e, 'repeat bitwise', np.array_equal(f, f2), flush=True)
        del c, integ

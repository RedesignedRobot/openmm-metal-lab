# Dump Metal forces for the Design 3 bitwise check, to compare two builds, and runs of one build, bit for bit.
# getState(getForces=True) alone is a force-only step, the one path that runs bonded and nonbonded concurrently;
# 20 Verlet steps then run that path 20 more times on a reused neighbor list.
# Usage (cwd ultra-base/benchmarks): dumpd3.py OUT.npz
import sys, numpy as np
bench = 'benchmark.py'
src = open(bench).read()
g = {'__name__': 'dumpd3'}
exec(compile(src[:src.index('def serializeTest')], bench, 'exec'), g)
import openmm as mm, openmm.unit as u
out = {}
for test in ['gbsa', 'rf', 'pme', 'apoa1rf', 'amber20-cellulose']:
    system, positions, _ = g['retrieveTestSystem'](test)
    for prec in ['single', 'mixed']:
        integrator = mm.VerletIntegrator(0.001)
        context = mm.Context(system, integrator, mm.Platform.getPlatformByName('Metal'), {'Precision': prec, 'DeterministicForces': 'true'})
        context.setPositions(positions)
        out[f'{test}-{prec}-f'] = context.getState(getForces=True).getForces(asNumpy=True).value_in_unit(u.kilojoule_per_mole/u.nanometer)
        out[f'{test}-{prec}-e'] = np.array(context.getState(getEnergy=True).getPotentialEnergy().value_in_unit(u.kilojoule_per_mole))
        integrator.step(20)
        out[f'{test}-{prec}-x20'] = context.getState(getPositions=True).getPositions(asNumpy=True).value_in_unit(u.nanometer)
        del context, integrator
        print(test, prec, flush=True)
np.savez(sys.argv[1], **out)
print('saved', sys.argv[1])

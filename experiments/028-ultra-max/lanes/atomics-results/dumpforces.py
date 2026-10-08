# Dump Metal forces and energies for the gate systems, to compare two plugin builds bit for bit.
# Usage: dumpforces.py OUT.npz
import sys, numpy as np
bench = '/tmp/openmm-metal-bench/ultra-atomics/src/examples/benchmarks/benchmark.py'
src = open(bench).read()
g = {'__name__': 'dumpforces'}
exec(compile(src[:src.index('def serializeTest')], bench, 'exec'), g)
import openmm as mm, openmm.unit as u
out = {}
for test in ['gbsa', 'rf', 'pme', 'apoa1rf', 'apoa1pme', 'apoa1ljpme']:
    system, positions, _ = g['retrieveTestSystem'](test)
    for prec in ['single', 'mixed']:
        context = mm.Context(system, mm.VerletIntegrator(0.001), mm.Platform.getPlatformByName('Metal'), {'Precision': prec, 'DeterministicForces': 'true'})
        context.setPositions(positions)
        state = context.getState(getForces=True, getEnergy=True)
        out[f'{test}-{prec}-f'] = state.getForces(asNumpy=True).value_in_unit(u.kilojoule_per_mole/u.nanometer)
        out[f'{test}-{prec}-e'] = np.array(state.getPotentialEnergy().value_in_unit(u.kilojoule_per_mole))
        del context
np.savez(sys.argv[1], **out)
print('saved', sys.argv[1])

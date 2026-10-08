import os
import sys
import math
import openmm as mm
import openmm.unit as unit

bench, platform_name, precision = sys.argv[1:]
os.chdir(bench)
source = open('benchmark.py').read()
exec(source[:source.index('def serializeTest')])
platform = mm.Platform.getPlatformByName(platform_name)
for name in ('gbsa', 'rf', 'pme', 'amber20-dhfr'):
    system, positions, _ = retrieveTestSystem(name)
    integrator = mm.LangevinMiddleIntegrator(300, 91 if name == 'gbsa' else 1, 0.004)
    integrator.setRandomNumberSeed(2026)
    integrator.setConstraintTolerance(1e-5)
    context = mm.Context(system, integrator, platform, {'Precision': precision})
    context.setPositions(positions)
    context.setVelocitiesToTemperature(300, 2026)
    integrator.step(1)
    energy = context.getState(getEnergy=True).getPotentialEnergy().value_in_unit(unit.kilojoule_per_mole)
    assert math.isfinite(energy), (name, energy)
    print('PASS one-step', platform_name, precision, name, flush=True)
    del context, integrator

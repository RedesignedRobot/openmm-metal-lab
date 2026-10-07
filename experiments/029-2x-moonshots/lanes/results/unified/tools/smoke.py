"""One benchmark-system MD step before admitting an A/B arm to the queue."""
import os
import sys
import openmm as mm
import openmm.unit as unit

bench, test, precision, platform = sys.argv[1:]
os.chdir(bench)
source = open('benchmark.py').read()
exec(source[:source.index('def serializeTest')])
system, positions, _ = retrieveTestSystem(test)
integrator = mm.LangevinMiddleIntegrator(300*unit.kelvin, 1/unit.picoseconds, 0.004*unit.picoseconds)
integrator.setConstraintTolerance(1e-5)
context = mm.Context(system, integrator, mm.Platform.getPlatformByName(platform), {'Precision': precision})
for force in system.getForces():
    if isinstance(force, mm.NonbondedForce) and force.getNonbondedMethod() in (mm.NonbondedForce.PME, mm.NonbondedForce.LJPME):
        try:
            if force.getNonbondedMethod() == mm.NonbondedForce.PME:
                print('PME grid', force.getPMEParametersInContext(context), flush=True)
            else:
                print('LJPME grid', force.getLJPMEParametersInContext(context), flush=True)
        except mm.OpenMMException as error:
            print('Grid metadata unavailable:', error, flush=True)
context.setPositions(positions)
if test.startswith('amber'):
    mm.LocalEnergyMinimizer.minimize(context, 100*unit.kilojoules_per_mole/unit.nanometer)
context.setVelocitiesToTemperature(300*unit.kelvin)
integrator.step(1)
state = context.getState(energy=True)
print('SMOKE PASS', test, precision, platform, state.getPotentialEnergy(), flush=True)

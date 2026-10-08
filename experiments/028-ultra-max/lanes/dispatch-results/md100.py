"""Forces after 100 MD steps against Reference, for neighbor list changes.

Runs 100 LangevinMiddle steps on Metal from the benchmark.py positions, then compares the forces of
that running context, whose neighbor list was built during the steps, with Reference at the same
positions.
usage: python md100.py <examples/benchmarks dir> <tests> <precision>
"""
import os
import sys

import numpy as np
import openmm as mm
import openmm.unit as u

bench = os.path.abspath(sys.argv[1])
tests = sys.argv[2].split(",")
precision = sys.argv[3]
os.chdir(bench)
# benchmark.py runs its benchmarks on import, so load only the definitions before serializeTest().
source = open("benchmark.py").read()
exec(source[:source.index("def serializeTest")])

print(f"{'test':12} {'atoms':>7} {'steps':>6} {'rel|dF|':>10} {'max|dF|':>10} {'rel|dE|':>10}")
for test in tests:
    system, positions, _ = retrieveTestSystem(test)
    integrator = mm.LangevinMiddleIntegrator(300*u.kelvin, 1/u.picosecond, 0.002*u.picoseconds)
    integrator.setRandomNumberSeed(1)
    context = mm.Context(system, integrator, mm.Platform.getPlatformByName("Metal"), {"Precision": precision})
    context.setPositions(positions)
    context.setVelocitiesToTemperature(300*u.kelvin, 1)
    for steps in (100, 200):
        integrator.step(100)
        state = context.getState(getPositions=True, getForces=True, getEnergy=True)
        f = state.getForces(asNumpy=True).value_in_unit(u.kilojoule_per_mole/u.nanometer)
        e = state.getPotentialEnergy().value_in_unit(u.kilojoule_per_mole)
        ref = mm.Context(system, mm.VerletIntegrator(0.001), mm.Platform.getPlatformByName("Reference"))
        ref.setPeriodicBoxVectors(*state.getPeriodicBoxVectors())
        ref.setPositions(state.getPositions())
        rstate = ref.getState(getForces=True, getEnergy=True)
        fref = rstate.getForces(asNumpy=True).value_in_unit(u.kilojoule_per_mole/u.nanometer)
        eref = rstate.getPotentialEnergy().value_in_unit(u.kilojoule_per_mole)
        rel = np.linalg.norm(f-fref)/np.linalg.norm(fref)
        print(f"{test:12} {system.getNumParticles():7d} {steps:6d} {rel:10.3e} {np.abs(f-fref).max():10.3e} "
              f"{abs(e-eref)/abs(eref):10.3e}", flush=True)
        del ref
    del context

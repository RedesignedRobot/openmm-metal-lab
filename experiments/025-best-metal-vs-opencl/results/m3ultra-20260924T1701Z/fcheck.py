"""Forces and energy of several platform configurations against Reference for the benchmark.py systems.

Adapted from experiments/025-best-metal-vs-opencl/forces.py: Reference runs once per test, in double,
and every configuration is compared with it.
usage: python fcheck.py <examples/benchmarks dir> <tests> <platform:precision,...>
Prints, per test and configuration, the relative force error |F-Fref|/|Fref|, the largest force
component error in kJ/mol/nm and the relative energy error.
"""
import os
import sys

import numpy as np
import openmm as mm
import openmm.unit as u

bench = os.path.abspath(sys.argv[1])
tests = sys.argv[2].split(",")
configs = [c.split(":") for c in sys.argv[3].split(",")]
os.chdir(bench)
# benchmark.py runs its benchmarks on import, so load only the definitions before serializeTest().
source = open("benchmark.py").read()
exec(source[:source.index("def serializeTest")])


def forces_and_energy(system, positions, platform, props):
    context = mm.Context(system, mm.VerletIntegrator(0.001), mm.Platform.getPlatformByName(platform), props)
    context.setPositions(positions)
    state = context.getState(getForces=True, getEnergy=True)
    forces = state.getForces(asNumpy=True).value_in_unit(u.kilojoule_per_mole/u.nanometer)
    return np.array(forces), state.getPotentialEnergy().value_in_unit(u.kilojoule_per_mole)


print(f"{'test':12} {'atoms':>7} {'config':>14} {'rel|dF|':>10} {'max|dF|':>10} {'rel|dE|':>10}")
for test in tests:
    system, positions, _ = retrieveTestSystem(test)
    fref, eref = forces_and_energy(system, positions, "Reference", {})
    for platform, precision in configs:
        f, e = forces_and_energy(system, positions, platform, {"Precision": precision})
        rel = np.linalg.norm(f-fref)/np.linalg.norm(fref)
        print(f"{test:12} {system.getNumParticles():7d} {platform + '-' + precision:>14} {rel:10.3e} "
              f"{np.abs(f-fref).max():10.3e} {abs(e-eref)/abs(eref):10.3e}", flush=True)

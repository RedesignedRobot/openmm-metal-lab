"""r2-pmefft: PME reciprocal force error of the dhfr grid before (55^3) and after (56^3) the change, both on
Reference with the same alpha, against a 112^3 grid. CPU only.
usage: python gridacc.py <benchmarks dir>
"""
import os
import sys

import numpy as np
import openmm as mm
import openmm.unit as u

os.chdir(sys.argv[1])
source = open("benchmark.py").read()
exec(source[:source.index("def serializeTest")])
system, positions, _ = retrieveTestSystem("amber20-dhfr")
nb = [f for f in system.getForces() if isinstance(f, mm.NonbondedForce)][0]
for f in system.getForces():
    f.setForceGroup(0)
nb.setReciprocalSpaceForceGroup(1)
probe = mm.Context(system, mm.VerletIntegrator(0.001), mm.Platform.getPlatformByName("Reference"))
alpha = nb.getPMEParametersInContext(probe)[0]
del probe


def recip(n):
    nb.setPMEParameters(alpha, n, n, n)
    context = mm.Context(system, mm.VerletIntegrator(0.001), mm.Platform.getPlatformByName("Reference"))
    context.setPositions(positions)
    state = context.getState(getForces=True, getEnergy=True, groups={1})
    return (np.array(state.getForces(asNumpy=True).value_in_unit(u.kilojoule_per_mole/u.nanometer)),
            state.getPotentialEnergy().value_in_unit(u.kilojoule_per_mole))


fine, efine = recip(112)
for n in (55, 56):
    f, e = recip(n)
    print(f"alpha {alpha:.6f} grid {n}^3  rel|dF| vs 112^3 {np.linalg.norm(f-fine)/np.linalg.norm(fine):.3e}  "
          f"rel|dE| {abs(e-efine)/abs(efine):.3e}", flush=True)

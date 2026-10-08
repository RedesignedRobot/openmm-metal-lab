"""How well Metal satisfies the constraints after some benchmark.py steps.

Runs <steps> steps of benchmark.py's integrator (LangevinMiddle, 4 fs) on <test> with the given constraint
tolerance, then measures every constraint from the double positions of getState, and the velocity
component along each constrained bond. Prints one JSON line with the largest and RMS relative length
errors, for water (SETTLE) and the other constraints (SHAKE) separately.
usage: python constraints.py <benchmarks dir> <test> <precision> <tolerance> <steps>
"""
import json
import os
import sys

import numpy as np
import openmm as mm
import openmm.unit as u

bench, test, precision = os.path.abspath(sys.argv[1]), sys.argv[2], sys.argv[3]
tolerance, steps = float(sys.argv[4]), int(sys.argv[5])
WATER_LENGTHS = (0.09572, 0.15139)

os.chdir(bench)
# benchmark.py runs its benchmarks on import, so load only the definitions before serializeTest().
source = open("benchmark.py").read()
exec(source[:source.index("def serializeTest")])

system, positions, _ = retrieveTestSystem(test)
integrator = mm.LangevinMiddleIntegrator(300*u.kelvin, 1/u.picosecond, 0.004*u.picoseconds)
integrator.setRandomNumberSeed(1)
integrator.setConstraintTolerance(tolerance)
context = mm.Context(system, integrator, mm.Platform.getPlatformByName("Metal"), {"Precision": precision})
context.setPositions(positions)
context.setVelocitiesToTemperature(300*u.kelvin, 1)
integrator.step(steps)
state = context.getState(getPositions=True, getVelocities=True)
pos = state.getPositions(asNumpy=True).value_in_unit(u.nanometer)
vel = state.getVelocities(asNumpy=True).value_in_unit(u.nanometer/u.picosecond)

pairs = np.array([system.getConstraintParameters(i)[:2] for i in range(system.getNumConstraints())])
lengths = np.array([system.getConstraintParameters(i)[2].value_in_unit(u.nanometer) for i in range(system.getNumConstraints())])
bonds = pos[pairs[:, 1]] - pos[pairs[:, 0]]
distance = np.linalg.norm(bonds, axis=1)
relative = np.abs(distance - lengths)/lengths
along = np.abs(np.sum((vel[pairs[:, 1]] - vel[pairs[:, 0]])*bonds, axis=1))/distance
water = np.isclose(lengths, WATER_LENGTHS[0], atol=1e-6) | np.isclose(lengths, WATER_LENGTHS[1], atol=1e-6)
result = {"test": test, "precision": precision, "tolerance": tolerance, "steps": steps,
          "openmm": mm.version.openmm_library_path}
for name, mask in (("settle", water), ("shake", ~water)):
    if mask.any():
        result[name] = {"n": int(mask.sum()), "max_rel_length": float(relative[mask].max()),
                        "rms_rel_length": float(np.sqrt(np.mean(relative[mask]**2))),
                        "max_vel_along": float(along[mask].max())}
print(json.dumps(result), flush=True)

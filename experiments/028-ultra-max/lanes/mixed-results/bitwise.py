"""Positions and velocities after some benchmark.py steps on Metal, to compare two builds bit for bit.

Runs <steps> steps of benchmark.py's integrator (LangevinMiddle, 4 fs, seed 1) on <test> with
DeterministicForces, starting from velocities drawn on the host with seed 1, and saves the positions
and velocities of getState to <out>.npz. getState converts float to double exactly, so equal arrays mean
equal device values in single precision.
usage: python bitwise.py <benchmarks dir> <test> <precision> <steps> <out.npz>
       python bitwise.py --compare <a.npz> <b.npz>
"""
import json
import os
import sys

import numpy as np

if sys.argv[1] == "--compare":
    a, b = np.load(sys.argv[2]), np.load(sys.argv[3])
    result = {"a": sys.argv[2], "b": sys.argv[3]}
    for key in ("positions", "velocities"):
        diff = np.abs(a[key] - b[key])
        result[key] = {"identical": bool(np.array_equal(a[key], b[key])), "atoms_differing": int(np.any(diff != 0, axis=1).sum()),
                       "max_abs_diff": float(diff.max())}
    print(json.dumps(result), flush=True)
    sys.exit(0)

import openmm as mm
import openmm.unit as u

bench, test, precision, steps, out = os.path.abspath(sys.argv[1]), sys.argv[2], sys.argv[3], int(sys.argv[4]), os.path.abspath(sys.argv[5])
os.chdir(bench)
# benchmark.py runs its benchmarks on import, so load only the definitions before serializeTest().
source = open("benchmark.py").read()
exec(source[:source.index("def serializeTest")])

system, positions, _ = retrieveTestSystem(test)
integrator = mm.LangevinMiddleIntegrator(300*u.kelvin, 1/u.picosecond, 0.004*u.picoseconds)
integrator.setRandomNumberSeed(1)
properties = {"Precision": precision, "DeterministicForces": "true"}
context = mm.Context(system, integrator, mm.Platform.getPlatformByName("Metal"), properties)
context.setPositions(positions)
context.setVelocitiesToTemperature(300*u.kelvin, 1)
integrator.step(steps)
state = context.getState(getPositions=True, getVelocities=True)
np.savez(out, positions=state.getPositions(asNumpy=True).value_in_unit(u.nanometer),
         velocities=state.getVelocities(asNumpy=True).value_in_unit(u.nanometer/u.picosecond))
print(json.dumps({"test": test, "precision": precision, "steps": steps, "out": out, "openmm": mm.version.openmm_library_path}), flush=True)

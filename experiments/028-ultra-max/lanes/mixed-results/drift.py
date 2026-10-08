"""NVE energy drift on Metal for one benchmark.py system, to compare two builds' mixed precision.

Builds the system with benchmark.py's retrieveTestSystem, draws velocities at 300 K from <seed> (on the
host, so both builds start identically), runs <integrator> at 2 fs for <ps> picoseconds, and
samples the total energy every 0.5 ps. Prints one JSON line: the least-squares slope of the total
energy in kJ/mol/ns and in kT/ns per degree of freedom, and the RMS of the residual around the fit.
<integrator> is "verlet" (VerletIntegrator: position constraints only), "vv" (velocity Verlet as a
CustomIntegrator, which also applies the velocity constraints, SETTLE and SHAKE, every step) or "lm0"
(LangevinMiddleIntegrator with zero friction, so no heat bath: position and velocity constraints every step).
usage: python drift.py <benchmarks dir> <test> <precision> <ps> <seed> <constraint tolerance> <integrator>
"""
import json
import os
import sys

import numpy as np
import openmm as mm
import openmm.unit as u

bench, test, precision = os.path.abspath(sys.argv[1]), sys.argv[2], sys.argv[3]
ps, seed, tolerance, kind = float(sys.argv[4]), int(sys.argv[5]), float(sys.argv[6]), sys.argv[7]
STEP_PS = 0.002
SAMPLE_STEPS = 250
KT = (u.MOLAR_GAS_CONSTANT_R*300*u.kelvin).value_in_unit(u.kilojoule_per_mole)

os.chdir(bench)
# benchmark.py runs its benchmarks on import, so load only the definitions before serializeTest().
source = open("benchmark.py").read()
exec(source[:source.index("def serializeTest")])


def velocity_verlet():
    integrator = mm.CustomIntegrator(STEP_PS)
    integrator.addPerDofVariable("x1", 0)
    integrator.addUpdateContextState()
    integrator.addComputePerDof("v", "v+0.5*dt*f/m")
    integrator.addComputePerDof("x", "x+dt*v")
    integrator.addComputePerDof("x1", "x")
    integrator.addConstrainPositions()
    integrator.addComputePerDof("v", "v+(x-x1)/dt")
    integrator.addComputePerDof("v", "v+0.5*dt*f/m")
    integrator.addConstrainVelocities()
    return integrator


system, positions, _ = retrieveTestSystem(test)
integrator = {"verlet": lambda: mm.VerletIntegrator(STEP_PS), "vv": velocity_verlet,
              "lm0": lambda: mm.LangevinMiddleIntegrator(300*u.kelvin, 0, STEP_PS)}[kind]()
integrator.setConstraintTolerance(tolerance)
context = mm.Context(system, integrator, mm.Platform.getPlatformByName("Metal"), {"Precision": precision})
context.setPositions(positions)
context.applyConstraints(tolerance)
context.setVelocitiesToTemperature(300*u.kelvin, seed)
context.applyVelocityConstraints(tolerance)

times, energies = [], []
for sample in range(int(round(ps/(SAMPLE_STEPS*STEP_PS))) + 1):
    if sample > 0:
        integrator.step(SAMPLE_STEPS)
    state = context.getState(getEnergy=True)
    times.append(state.getTime().value_in_unit(u.nanosecond))
    energies.append((state.getPotentialEnergy() + state.getKineticEnergy()).value_in_unit(u.kilojoule_per_mole))
times, energies = np.array(times), np.array(energies)
slope, intercept = np.polyfit(times, energies, 1)
dof = 3*system.getNumParticles() - system.getNumConstraints() - 3
print(json.dumps({"test": test, "precision": precision, "ps": ps, "seed": seed, "tolerance": tolerance,
                  "integrator": kind,
                  "openmm": mm.version.openmm_library_path, "drift_kj_per_ns": slope,
                  "drift_kt_per_ns_per_dof": slope/KT/dof,
                  "rms_kj": float(np.sqrt(np.mean((energies - (slope*times + intercept))**2))),
                  "e_first": energies[0], "e_last": energies[-1]}), flush=True)

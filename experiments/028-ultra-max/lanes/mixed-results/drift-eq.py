"""NVE energy drift after equilibration, on <platform> (default Metal), for one benchmark.py system.

Builds the system with benchmark.py's retrieveTestSystem, draws velocities at 300 K from <seed>, runs
LangevinMiddleIntegrator at 2 fs with friction 1/ps for <equil ps> (random stream also from <seed>),
then sets the friction to 0 and runs <ps> picoseconds, sampling the total energy every 0.5 ps.
Prints one JSON line: the least-squares slope of the total energy in kJ/mol/ns and in kT/ns per degree
of freedom, the RMS of the residual, the white-noise slope standard error, and a block standard error
per block length: the slope fitted to block-mean energies, whose SE stays honest once blocks are longer
than the correlation time of the residuals.
The CPU platform has no Precision property; it always runs mixed.
usage: python drift-eq.py <benchmarks dir> <test> <precision> <equil ps> <ps> <seed> <constraint tolerance> [platform]
"""
import json
import os
import sys

import numpy as np
import openmm as mm
import openmm.unit as u

bench, test, precision = os.path.abspath(sys.argv[1]), sys.argv[2], sys.argv[3]
equil_ps, ps, seed, tolerance = float(sys.argv[4]), float(sys.argv[5]), int(sys.argv[6]), float(sys.argv[7])
platform = sys.argv[8] if len(sys.argv) > 8 else "Metal"
STEP_PS = 0.002
SAMPLE_STEPS = 250
EQUIL_FRICTION = 1/u.picosecond
BLOCK_PS = (2.5, 5, 10, 20)
KT = (u.MOLAR_GAS_CONSTANT_R*300*u.kelvin).value_in_unit(u.kilojoule_per_mole)

os.chdir(bench)
# benchmark.py runs its benchmarks on import, so load only the definitions before serializeTest().
source = open("benchmark.py").read()
exec(source[:source.index("def serializeTest")])


def slope_and_se(times, energies):
    slope, intercept = np.polyfit(times, energies, 1)
    residual = energies - (slope*times + intercept)
    sxx = np.sum((times - times.mean())**2)
    return slope, float(np.sqrt(np.sum(residual**2)/(len(times) - 2)/sxx)), residual


system, positions, _ = retrieveTestSystem(test)
integrator = mm.LangevinMiddleIntegrator(300*u.kelvin, EQUIL_FRICTION, STEP_PS)
integrator.setConstraintTolerance(tolerance)
integrator.setRandomNumberSeed(seed)
properties = {} if platform == "CPU" else {"Precision": precision}
context = mm.Context(system, integrator, mm.Platform.getPlatformByName(platform), properties)
context.setPositions(positions)
context.applyConstraints(tolerance)
context.setVelocitiesToTemperature(300*u.kelvin, seed)
context.applyVelocityConstraints(tolerance)
integrator.step(int(round(equil_ps/STEP_PS)))
integrator.setFriction(0)

times, energies = [], []
for sample in range(int(round(ps/(SAMPLE_STEPS*STEP_PS))) + 1):
    if sample > 0:
        integrator.step(SAMPLE_STEPS)
    state = context.getState(getEnergy=True)
    times.append(state.getTime().value_in_unit(u.nanosecond))
    energies.append((state.getPotentialEnergy() + state.getKineticEnergy()).value_in_unit(u.kilojoule_per_mole))
times, energies = np.array(times), np.array(energies)
slope, se_white, residual = slope_and_se(times, energies)

# Block means start after the first sample, so every block holds the same number of samples.
se_block = {}
for block_ps in BLOCK_PS:
    per_block = int(round(block_ps/(SAMPLE_STEPS*STEP_PS)))
    blocks = (len(times) - 1)//per_block
    if blocks < 4:
        continue
    used = slice(1, 1 + blocks*per_block)
    block_times = times[used].reshape(blocks, per_block).mean(axis=1)
    block_energies = energies[used].reshape(blocks, per_block).mean(axis=1)
    se_block[str(block_ps)] = slope_and_se(block_times, block_energies)[1]

dof = 3*system.getNumParticles() - system.getNumConstraints() - 3
print(json.dumps({"test": test, "platform": platform, "precision": precision, "equil_ps": equil_ps, "ps": ps, "seed": seed,
                  "tolerance": tolerance, "openmm": mm.version.openmm_library_path,
                  "drift_kj_per_ns": slope, "drift_kt_per_ns_per_dof": slope/KT/dof,
                  "rms_kj": float(np.sqrt(np.mean(residual**2))), "se_white_kj_per_ns": se_white,
                  "se_block_kj_per_ns": se_block, "e_first": energies[0], "e_last": energies[-1]}), flush=True)

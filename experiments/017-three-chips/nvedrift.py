"""Total-energy drift of a FAHBench work unit run as NVE with its own Verlet integrator.

usage: python nvedrift.py <wu-dir> <platform> <precision> [steps] [interval]
Prints one JSON line. Starts from the work unit's state (positions and velocities), keeps the
work unit's constraints and constraint tolerance, and samples kinetic + potential energy every
`interval` steps. Drift is the least-squares slope of total energy against time.
"""
import json
import sys
import time

import numpy as np
import openmm as mm
import openmm.unit as u

KT_300K = (u.MOLAR_GAS_CONSTANT_R * 300 * u.kelvin).value_in_unit(u.kilojoule_per_mole)


def load(wu):
    read = lambda name: mm.XmlSerializer.deserialize(
        open(f"{wu}/{name}").read().replace("stateCheckpoint", "State"))
    return read("system.xml"), read("integrator.xml"), read("state.xml")


def main():
    wu, platform, precision = sys.argv[1:4]
    steps = int(sys.argv[4]) if len(sys.argv) > 4 else 50000
    interval = int(sys.argv[5]) if len(sys.argv) > 5 else 250
    props = {} if platform in ("CPU", "Reference") else {"Precision": precision}

    system, integrator, state = load(wu)
    if not isinstance(integrator, mm.VerletIntegrator):
        sys.exit(f"{wu} does not use a VerletIntegrator")
    ensemble_forces = [i for i, f in enumerate(system.getForces())
                       if isinstance(f, (mm.AndersenThermostat, mm.MonteCarloBarostat))]
    if ensemble_forces:
        sys.exit(f"{wu} has thermostat or barostat forces {ensemble_forces}; not NVE")
    context = mm.Context(system, integrator, mm.Platform.getPlatformByName(platform), props)
    context.setState(state)

    times, energies = [], []
    start = time.perf_counter()
    for block in range(steps // interval + 1):
        if block:
            integrator.step(interval)
        s = context.getState(getEnergy=True)
        times.append(s.getTime().value_in_unit(u.nanosecond))
        energies.append((s.getKineticEnergy() + s.getPotentialEnergy()).value_in_unit(u.kilojoule_per_mole))
    elapsed = time.perf_counter() - start

    t, e = np.array(times) - times[0], np.array(energies)
    slope, intercept = np.polyfit(t, e, 1)
    dof = 3 * system.getNumParticles() - system.getNumConstraints() - 3
    print(json.dumps({
        "wu": wu.rstrip("/").split("/")[-1], "atoms": system.getNumParticles(),
        "platform": platform, "precision": precision if props else "native",
        "steps": steps, "step_fs": integrator.getStepSize().value_in_unit(u.femtosecond),
        "constraint_tol": integrator.getConstraintTolerance(), "dof": dof,
        "sim_ns": float(t[-1]), "wall_s": round(elapsed, 1),
        "drift_kj_mol_per_ns": float(slope),
        "drift_kT_per_ns_per_dof": float(slope / KT_300K / dof),
        "rms_about_fit_kj_mol": float(np.sqrt(np.mean((e - (slope * t + intercept)) ** 2))),
        "e_first": energies[0], "e_last": energies[-1],
    }))


if __name__ == "__main__":
    main()

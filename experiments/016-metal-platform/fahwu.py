"""Run a FAHBench work unit on one OpenMM platform and report speed and agreement with Reference.

usage: python fahwu.py <wu-dir> <platform> <precision> [seconds]
Prints one JSON line. Speed is host wall clock over whole steps, after a warm-up.
Agreement compares forces and potential energy at the work unit's start state against
the Reference platform in double precision, the same check FAHBench runs.
"""
import json
import sys
import time

import numpy as np
import openmm as mm
import openmm.unit as u


def load(wu):
    # FAHBench ships its states under the pre-7.0 root tag; current OpenMM reads <State>.
    read = lambda name: mm.XmlSerializer.deserialize(
        open(f"{wu}/{name}").read().replace("stateCheckpoint", "State"))
    return read("system.xml"), read("integrator.xml"), read("state.xml")


def forces_and_energy(system, integrator, state, platform, props):
    context = mm.Context(system, integrator, mm.Platform.getPlatformByName(platform), props)
    context.setState(state)
    s = context.getState(getForces=True, getEnergy=True)
    return (s.getForces(asNumpy=True).value_in_unit(u.kilojoule_per_mole / u.nanometer),
            s.getPotentialEnergy().value_in_unit(u.kilojoule_per_mole))


def main():
    wu, platform, precision = sys.argv[1:4]
    seconds = float(sys.argv[4]) if len(sys.argv) > 4 else 30.0
    props = {} if platform in ("CPU", "Reference") else {"Precision": precision}

    system, integrator, state = load(wu)
    f, e = forces_and_energy(system, integrator, state, platform, props)
    system, integrator, state = load(wu)
    f_ref, e_ref = forces_and_energy(system, integrator, state, "Reference", {})
    rel_force = float(np.linalg.norm(f - f_ref) / np.linalg.norm(f_ref))

    system, integrator, state = load(wu)
    context = mm.Context(system, integrator, mm.Platform.getPlatformByName(platform), props)
    context.setState(state)
    integrator.step(200)
    context.getState(getEnergy=True)
    steps, start = 0, time.perf_counter()
    while time.perf_counter() - start < seconds:
        integrator.step(100)
        context.getState(getEnergy=True)
        steps += 100
    elapsed = time.perf_counter() - start
    step_ps = integrator.getStepSize().value_in_unit(u.picosecond)

    print(json.dumps({
        "wu": wu.rstrip("/").split("/")[-1], "atoms": system.getNumParticles(),
        "platform": platform, "precision": precision if props else "native",
        "ns_per_day": steps * step_ps / 1000 / elapsed * 86400,
        "steps": steps, "wall_s": round(elapsed, 2),
        "rel_force_err": rel_force, "energy": e, "energy_ref": e_ref,
        "energy_rel_err": abs(e - e_ref) / abs(e_ref),
        "clock": "host wall, whole steps",
    }))


if __name__ == "__main__":
    main()

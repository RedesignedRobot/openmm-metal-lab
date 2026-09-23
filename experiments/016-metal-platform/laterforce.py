"""Force agreement with Reference after a work unit has run for a while, not just at its start state.

usage: python laterforce.py <wu-dir> <platform> <precision> [steps=5000]
Prints one JSON line. Runs the work unit's own integrator for `steps` steps on <platform>, then
compares forces and potential energy at the resulting positions against Reference in double.
"""
import json
import sys

import numpy as np
import openmm as mm
import openmm.unit as u


def load(wu):
    read = lambda name: mm.XmlSerializer.deserialize(
        open(f"{wu}/{name}").read().replace("stateCheckpoint", "State"))
    return read("system.xml"), read("integrator.xml"), read("state.xml")


def forces_and_energy(context):
    s = context.getState(getForces=True, getEnergy=True)
    return (s.getForces(asNumpy=True).value_in_unit(u.kilojoule_per_mole / u.nanometer),
            s.getPotentialEnergy().value_in_unit(u.kilojoule_per_mole))


def main():
    wu, platform, precision = sys.argv[1:4]
    steps = int(sys.argv[4]) if len(sys.argv) > 4 else 5000
    props = {} if platform in ("CPU", "Reference") else {"Precision": precision}

    system, integrator, state = load(wu)
    context = mm.Context(system, integrator, mm.Platform.getPlatformByName(platform), props)
    context.setState(state)
    integrator.step(steps)
    later = context.getState(getPositions=True, enforcePeriodicBox=False)
    f, e = forces_and_energy(context)

    system, integrator, _ = load(wu)
    reference = mm.Context(system, integrator, mm.Platform.getPlatformByName("Reference"))
    reference.setPeriodicBoxVectors(*later.getPeriodicBoxVectors())
    reference.setPositions(later.getPositions())
    f_ref, e_ref = forces_and_energy(reference)

    print(json.dumps({
        "wu": wu.rstrip("/").split("/")[-1], "platform": platform,
        "precision": precision if props else "native", "steps": steps,
        "rel_force_err": float(np.linalg.norm(f - f_ref) / np.linalg.norm(f_ref)),
        "energy": e, "energy_ref": e_ref, "energy_rel_err": abs(e - e_ref) / abs(e_ref),
    }))


if __name__ == "__main__":
    main()

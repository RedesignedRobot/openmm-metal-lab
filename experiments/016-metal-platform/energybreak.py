"""Per-force energy error of a work unit's start state, against Reference in double.

usage: python energybreak.py <wu-dir> [contexts=3]
Puts each force in its own force group (PME reciprocal space in one more) and prints one JSON line per (run, context, group), where
group "total" is the energy of all groups together. Errors are relative to the total Reference
energy, so the groups show how much each force contributes to the total error.

- Reference is evaluated at the state's double positions and at those positions rounded to float,
  which is what the GPU platforms evaluate.
- "sum_of_groups" minus "total" isolates the energy reduction.
- Run "Metal-preciseRECIP" sets OPENMM_METAL_PRECISE_RECIP=1 before creating the context. That only
  has an effect in a temporary build that reads it; the shipped build ignores it.
"""
import json
import os
import sys

import numpy as np
import openmm as mm
import openmm.unit as u

RUNS = [("Metal", "single", None), ("Metal", "single", "preciseRECIP"), ("OpenCL", "single", None)]


def load(wu):
    read = lambda name: mm.XmlSerializer.deserialize(
        open(f"{wu}/{name}").read().replace("stateCheckpoint", "State"))
    system, state = read("system.xml"), read("state.xml")
    for i, force in enumerate(system.getForces()):
        force.setForceGroup(i)
        if isinstance(force, mm.NonbondedForce) and force.usesPeriodicBoundaryConditions():
            force.setReciprocalSpaceForceGroup(system.getNumForces())
    return system, state


def energies(context, groups):
    energy = lambda g: context.getState(getEnergy=True, groups=g).getPotentialEnergy().value_in_unit(u.kilojoule_per_mole)
    result = {name: energy({i}) for i, name in groups}
    result["total"] = energy(-1)
    result["sum_of_groups"] = sum(result[name] for _, name in groups)
    return result


def context_at(system, platform, props, positions, box):
    context = mm.Context(system, mm.VerletIntegrator(0.001), mm.Platform.getPlatformByName(platform), props)
    context.setPeriodicBoxVectors(*box)
    context.setPositions(positions)
    return context


def main():
    wu = sys.argv[1]
    contexts = int(sys.argv[2]) if len(sys.argv) > 2 else 3
    system, state = load(wu)
    groups = [(i, type(f).__name__) for i, f in enumerate(system.getForces()) if not isinstance(f, (mm.CMMotionRemover, mm.MonteCarloBarostat))]
    if any(isinstance(f, mm.NonbondedForce) and f.getReciprocalSpaceForceGroup() >= 0 for f in system.getForces()):
        groups.append((system.getNumForces(), "NonbondedForce reciprocal"))
    positions = state.getPositions(asNumpy=True).value_in_unit(u.nanometer)
    box = state.getPeriodicBoxVectors()
    rounded = positions.astype(np.float32).astype(np.float64)
    reference = {pos: energies(context_at(system, "Reference", {}, p, box), groups)
                 for pos, p in (("double", positions), ("float", rounded))}
    scale = abs(reference["double"]["total"])
    for pos in ("double", "float"):
        print(json.dumps({"wu": os.path.basename(wu.rstrip("/")), "run": f"Reference at {pos} positions", "energies": reference[pos]}), flush=True)

    for platform, precision, variant in RUNS:
        if variant == "preciseRECIP":
            os.environ["OPENMM_METAL_PRECISE_RECIP"] = "1"
        else:
            os.environ.pop("OPENMM_METAL_PRECISE_RECIP", None)
        run = f"{platform}-{variant}" if variant else platform
        for c in range(contexts):
            e = energies(context_at(system, platform, {"Precision": precision}, positions, box), groups)
            print(json.dumps({
                "wu": os.path.basename(wu.rstrip("/")), "run": run, "context": c,
                "err_vs_double_positions": {k: (e[k] - reference["double"][k]) / scale for k in e},
                "err_vs_float_positions": {k: (e[k] - reference["float"][k]) / scale for k in e},
            }), flush=True)


if __name__ == "__main__":
    main()

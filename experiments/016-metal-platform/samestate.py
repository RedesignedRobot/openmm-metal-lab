"""Force agreement of several platforms at the same later states of one trajectory.

usage: python samestate.py <wu-dir> <trajectory-platform> <trajectory-precision> <steps>...
Runs the work unit's own integrator on the trajectory platform and, after each cumulative step
count, evaluates forces at those exact positions on every platform below and on Reference in
double. Prints one JSON line per (state, platform). Shows whether an error belongs to the state
(every platform sees it) or to one platform. The worst atom's share of the squared error tells a
single close contact from error spread over the system.

GPU force kernels read positions as float, even in mixed precision, where getState returns the
double position (float plus correction). So each platform is also compared with Reference at the
positions rounded to float: the positions the GPU actually evaluated.
"""
import json
import sys

import numpy as np
import openmm as mm
import openmm.unit as u

EVALUATORS = [("Metal", "single"), ("Metal", "mixed"), ("OpenCL", "single"), ("CPU", "native")]


def load(wu):
    read = lambda name: mm.XmlSerializer.deserialize(
        open(f"{wu}/{name}").read().replace("stateCheckpoint", "State"))
    return read("system.xml"), read("integrator.xml"), read("state.xml")


def context_on(wu, platform, precision):
    system, _, _ = load(wu)
    props = {} if platform in ("CPU", "Reference") else {"Precision": precision}
    return mm.Context(system, mm.VerletIntegrator(0.001), mm.Platform.getPlatformByName(platform), props)


def forces_and_energy(context):
    s = context.getState(getForces=True, getEnergy=True)
    return (s.getForces(asNumpy=True).value_in_unit(u.kilojoule_per_mole / u.nanometer),
            s.getPotentialEnergy().value_in_unit(u.kilojoule_per_mole))


def reference_at(reference, positions, box):
    reference.setPeriodicBoxVectors(*box)
    reference.setPositions(positions)
    return forces_and_energy(reference)


def compare(f, e, f_ref, e_ref, f_ref32):
    atom_err = np.sum((f - f_ref) ** 2, axis=1)
    worst = int(np.argmax(atom_err))
    return {
        "rel_force_err": float(np.linalg.norm(f - f_ref) / np.linalg.norm(f_ref)),
        "rel_force_err_float_positions": float(np.linalg.norm(f - f_ref32) / np.linalg.norm(f_ref32)),
        "energy_rel_err": abs(e - e_ref) / abs(e_ref),
        "worst_atom": worst, "worst_atom_share": float(atom_err[worst] / atom_err.sum()),
        "worst_atom_force": float(np.linalg.norm(f_ref[worst])),
    }


def main():
    wu, platform, precision = sys.argv[1:4]
    checkpoints = [int(s) for s in sys.argv[4:]]
    system, integrator, state = load(wu)
    props = {} if platform in ("CPU", "Reference") else {"Precision": precision}
    trajectory = mm.Context(system, integrator, mm.Platform.getPlatformByName(platform), props)
    trajectory.setState(state)
    reference = context_on(wu, "Reference", "double")
    evaluators = {run: context_on(wu, *run) for run in EVALUATORS}

    done = 0
    for steps in checkpoints:
        integrator.step(steps - done)
        done = steps
        s = trajectory.getState(getPositions=True, enforcePeriodicBox=False)
        positions, box = s.getPositions(asNumpy=True), s.getPeriodicBoxVectors()
        rounded = positions.value_in_unit(u.nanometer).astype(np.float32).astype(np.float64) * u.nanometer
        f_ref32, _ = reference_at(reference, rounded, box)
        f_ref, e_ref = reference_at(reference, positions, box)
        runs = [("trajectory context", platform, precision, trajectory)]
        runs += [("fresh context", p, q, c) for (p, q), c in evaluators.items()]
        for kind, p, q, context in runs:
            if kind == "fresh context":
                context.setPeriodicBoxVectors(*box)
                context.setPositions(positions)
            f, e = forces_and_energy(context)
            print(json.dumps({"wu": wu.rstrip("/").split("/")[-1], "trajectory": f"{platform} {precision}",
                              "steps": steps, "evaluated_on": f"{p} {q}", "context": kind,
                              **compare(f, e, f_ref, e_ref, f_ref32)}), flush=True)


if __name__ == "__main__":
    main()

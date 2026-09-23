"""Minimize a FAHBench work unit from its start state on one platform and report the result.

usage: python minwu.py <wu-dir> <platform> <precision> [tolerance]
Prints one JSON line.  Wall time is host wall clock around LocalEnergyMinimizer.minimize, after a
one-iteration warm-up that compiles the kernels.  A second minimization with a reporter counts
iterations over all restraint-strength passes; it must end at the same positions.  The final state is scored on the Reference
platform so every platform is judged by the same double-precision forces: energy, and the force
with its components along constraints removed, as RMS over particles (the quantity the tolerance
bounds) and max over particles.
"""
import hashlib
import json
import sys
import time

import numpy as np
import openmm as mm
import openmm.unit as u


def load(wu):
    read = lambda name: mm.XmlSerializer.deserialize(
        open(f"{wu}/{name}").read().replace("stateCheckpoint", "State"))
    return read("system.xml"), read("integrator.xml"), read("state.xml")


class Counter(mm.MinimizationReporter):
    """Counts iterations over all L-BFGS passes; each restraint-strength pass restarts at 0."""
    iterations = 0
    passes = 0

    def report(self, iteration, x, grad, args):
        self.iterations += 1
        if iteration == 0:
            self.passes += 1
        return False


def minimize(system, integrator, state, platform, props, tolerance, reporter=None):
    context = mm.Context(system, integrator, mm.Platform.getPlatformByName(platform), props)
    context.setState(state)
    mm.LocalEnergyMinimizer.minimize(context, tolerance, 1)
    context.setState(state)
    start = time.perf_counter()
    if reporter is None:
        mm.LocalEnergyMinimizer.minimize(context, tolerance)
    else:
        mm.LocalEnergyMinimizer.minimize(context, tolerance, 0, reporter)
    wall = time.perf_counter() - start
    final = context.getState(getPositions=True, getEnergy=True)
    positions = final.getPositions(asNumpy=True).value_in_unit(u.nanometer)
    energy = final.getPotentialEnergy().value_in_unit(u.kilojoule_per_mole)
    return positions, energy, wall


def projected_forces(system, forces, positions):
    """Remove from each rigid cluster's forces their least-squares fit by constraint forces."""
    parent = list(range(system.getNumParticles()))

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    constraints = [system.getConstraintParameters(i)[:2] for i in range(system.getNumConstraints())]
    for i, j in constraints:
        parent[find(i)] = find(j)
    clusters = {}
    for i, j in constraints:
        clusters.setdefault(find(i), []).append((i, j))
    result = forces.copy()
    for pairs in clusters.values():
        atoms = sorted({a for pair in pairs for a in pair})
        column = {a: k for k, a in enumerate(atoms)}
        jacobian = np.zeros((3 * len(atoms), len(pairs)))
        for c, (i, j) in enumerate(pairs):
            delta = positions[j] - positions[i]
            jacobian[3 * column[j]:3 * column[j] + 3, c] = delta
            jacobian[3 * column[i]:3 * column[i] + 3, c] = -delta
        f = forces[atoms].reshape(-1)
        multipliers = np.linalg.lstsq(jacobian, f, rcond=None)[0]
        result[atoms] = (f - jacobian @ multipliers).reshape(-1, 3)
    return result


def main():
    wu, platform, precision = sys.argv[1:4]
    tolerance = float(sys.argv[4]) if len(sys.argv) > 4 else 10.0
    props = {} if platform in ("CPU", "Reference") else {"Precision": precision}

    positions, energy, wall = minimize(*load(wu), platform, props, tolerance)
    counter = Counter()
    positions2, _, _ = minimize(*load(wu), platform, props, tolerance, counter)

    system, integrator, state = load(wu)
    context = mm.Context(system, integrator, mm.Platform.getPlatformByName("Reference"))
    context.setState(state)
    context.setPositions(positions)
    scored = context.getState(getForces=True, getEnergy=True)
    forces = scored.getForces(asNumpy=True).value_in_unit(u.kilojoule_per_mole / u.nanometer)
    projected = np.linalg.norm(projected_forces(system, forces, positions), axis=1)
    distances = [system.getConstraintParameters(i) for i in range(system.getNumConstraints())]
    constraint_error = max((abs(np.linalg.norm(positions[j] - positions[i]) - d.value_in_unit(u.nanometer)) / d.value_in_unit(u.nanometer)
                            for i, j, d in distances), default=0.0)

    print(json.dumps({
        "wu": wu.rstrip("/").split("/")[-1], "atoms": system.getNumParticles(),
        "platform": platform, "precision": precision if props else "native", "tolerance": tolerance,
        "energy": energy, "energy_ref": scored.getPotentialEnergy().value_in_unit(u.kilojoule_per_mole),
        "rms_force_ref": float(np.sqrt(np.mean(projected ** 2))), "max_force_ref": float(projected.max()),
        "max_constraint_error": constraint_error,
        "iterations": counter.iterations, "passes": counter.passes, "wall_s": round(wall, 3),
        "positions_sha": hashlib.sha256(positions.tobytes()).hexdigest()[:16],
        "reporter_run_same_positions": bool(np.array_equal(positions, positions2)),
        "clock": "host wall around minimize",
    }))


if __name__ == "__main__":
    main()

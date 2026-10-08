"""AMOEBA forces and energy on Metal against Reference, repeated, to catch a missing barrier.
For amoebagk and amoebapme in single and mixed: 5 fresh Contexts with the default properties and 5 with
DeterministicForces, each compared with Reference, and each run compared bitwise with the first of its set.
Reference runs in double on the CPU and is cached in <cache dir>/<test>.npz; --reference-only just
writes the cache, so the GPU hold covers only the Metal evaluations.
usage: python amoebaforces.py [--reference-only] <benchmarks dir> <cache dir>
"""
import argparse
import os
import sys

import numpy as np
import openmm as mm
import openmm.unit as u

TESTS = ["amoebagk", "amoebapme"]
PRECISIONS = ["single", "mixed"]
REPEATS = 5

parser = argparse.ArgumentParser()
parser.add_argument("--reference-only", action="store_true")
parser.add_argument("bench")
parser.add_argument("cache")
args = parser.parse_args()
cache = os.path.abspath(args.cache)
os.makedirs(cache, exist_ok=True)
os.chdir(os.path.abspath(args.bench))
# benchmark.py runs its benchmarks on import, so load only the definitions before serializeTest().
source = open("benchmark.py").read()
exec(source[:source.index("def serializeTest")])


def evaluate(system, positions, platform, properties):
    context = mm.Context(system, mm.VerletIntegrator(0.001), mm.Platform.getPlatformByName(platform), properties)
    context.setPositions(positions)
    state = context.getState(getForces=True, getEnergy=True)
    forces = np.array(state.getForces(asNumpy=True).value_in_unit(u.kilojoule_per_mole/u.nanometer))
    return forces, state.getPotentialEnergy().value_in_unit(u.kilojoule_per_mole)


def reference(test, system, positions):
    path = os.path.join(cache, f"{test}.npz")
    start = np.array(positions.value_in_unit(u.nanometer))
    if os.path.exists(path):
        cached = np.load(path)
        if not np.array_equal(cached["positions"], start):
            sys.exit(f"{path} was written for other positions")
        return cached["forces"], float(cached["energy"])
    forces, energy = evaluate(system, positions, "Reference", {})
    np.savez(os.path.join(cache, f".{test}.npz"), positions=start, forces=forces, energy=energy)
    os.replace(os.path.join(cache, f".{test}.npz"), path)
    return forces, energy


print(f"{'test':10} {'precision':9} {'mode':13} {'run':>3} {'rel|dF|':>10} {'max|dF|':>10} {'rel|dE|':>10}", flush=True)
for test in TESTS:
    system, positions, _ = retrieveTestSystem(test)
    fref, eref = reference(test, system, positions)
    if args.reference_only:
        print(f"{test}: Reference cached", flush=True)
        continue
    for precision in PRECISIONS:
        for mode in ["default", "deterministic"]:
            properties = {"Precision": precision, "DeterministicForces": "true" if mode == "deterministic" else "false"}
            runs = [evaluate(system, positions, "Metal", properties) for _ in range(REPEATS)]
            for i, (f, e) in enumerate(runs):
                print(f"{test:10} {precision:9} {mode:13} {i+1:3d} {np.linalg.norm(f-fref)/np.linalg.norm(fref):10.3e} "
                      f"{np.abs(f-fref).max():10.3e} {abs(e-eref)/abs(eref):10.3e}", flush=True)
            f0, e0 = runs[0]
            same_forces = sum(np.array_equal(f, f0) for f, _ in runs)
            same_energy = sum(e == e0 for _, e in runs)
            spread = max(np.abs(f-f0).max() for f, _ in runs)
            print(f"{test:10} {precision:9} {mode:13} bitwise equal to run 1: forces {same_forces}/{REPEATS}, "
                  f"energy {same_energy}/{REPEATS}, max|F-F1| {spread:.3e}", flush=True)

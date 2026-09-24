"""Metal's DeterministicForces property on the six small benchmark.py systems, single and mixed.

With the property set, the same positions must give bitwise identical forces and energy: twice in one
Context, and once more in a fresh Context. The integrated gate runs it after every merge, since a
change to force accumulation (float atomics, partial force buffers) can break the property while
forces.py still passes. Writes the table to <out>; the exit code is 1 if any row differs.
usage: python detforces.py <benchmarks dir> <out>
"""
import os
import sys

import numpy as np
import openmm as mm
import openmm.unit as u

TESTS = ["gbsa", "rf", "pme", "apoa1rf", "apoa1pme", "apoa1ljpme"]
PRECISIONS = ["single", "mixed"]

if len(sys.argv) != 3:
    sys.exit("usage: python detforces.py <benchmarks dir> <out>")
bench = os.path.abspath(sys.argv[1])
out_path = os.path.abspath(sys.argv[2])
os.chdir(bench)
# benchmark.py runs its benchmarks on import, so load only the definitions before serializeTest().
source = open("benchmark.py").read()
exec(source[:source.index("def serializeTest")])


def evaluate(context, positions):
    context.setPositions(positions)
    state = context.getState(getForces=True, getEnergy=True)
    forces = state.getForces(asNumpy=True).value_in_unit(u.kilojoule_per_mole/u.nanometer)
    return np.array(forces), state.getPotentialEnergy().value_in_unit(u.kilojoule_per_mole)


def context(system, precision):
    return mm.Context(system, mm.VerletIntegrator(0.001), mm.Platform.getPlatformByName("Metal"),
                      {"Precision": precision, "DeterministicForces": "true"})


failed = False
with open(out_path, "w") as out:
    header = f"{'test':12} {'precision':>9} {'same Context':>14} {'new Context':>14}"
    print(header, file=out, flush=True)
    print(header, flush=True)
    for test in TESTS:
        system, positions, _ = retrieveTestSystem(test)
        for precision in PRECISIONS:
            first = context(system, precision)
            f1, e1 = evaluate(first, positions)
            f2, e2 = evaluate(first, positions)
            del first
            f3, e3 = evaluate(context(system, precision), positions)
            same = np.array_equal(f1, f2) and e1 == e2
            fresh = np.array_equal(f1, f3) and e1 == e3
            row = (f"{test:12} {precision:>9} {'identical' if same else 'DIFFERS':>14} "
                   f"{'identical' if fresh else 'DIFFERS':>14}")
            if not (same and fresh):
                failed = True
                row += f"  FAIL max|dF| {max(np.abs(f1-f2).max(), np.abs(f1-f3).max()):.3e}"
            print(row, file=out, flush=True)
            print(row, flush=True)
sys.exit(1 if failed else 0)

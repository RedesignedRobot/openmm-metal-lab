"""AMOEBA forces on Metal against Reference, and bitwise repeats under DeterministicForces.

forces.py covers the six fixed-charge systems; this covers the AMOEBA plugin (default amoebagk,
mutual polarization at benchmark.py's epsilon). Reference runs once per test, in double. Per
precision, Metal evaluates three times with DeterministicForces set, twice in one Context and once
in a fresh one; the three must be bitwise identical, and the first is compared with Reference.
Writes the table to <out>; the exit code is 1 if the repeats differ.
usage: python amoebaforces.py <benchmarks dir> <out> [test...]
"""
import os
import sys
import time

import numpy as np
import openmm as mm
import openmm.unit as u

PRECISIONS = ["single", "mixed"]

if len(sys.argv) < 3:
    sys.exit("usage: python amoebaforces.py <benchmarks dir> <out> [test...]")
bench = os.path.abspath(sys.argv[1])
out_path = os.path.abspath(sys.argv[2])
tests = sys.argv[3:] or ["amoebagk"]
os.chdir(bench)
# benchmark.py runs its benchmarks on import, so load only the definitions before serializeTest().
source = open("benchmark.py").read()
exec(source[:source.index("def serializeTest")])


def evaluate(context, positions):
    context.setPositions(positions)
    state = context.getState(getForces=True, getEnergy=True)
    forces = state.getForces(asNumpy=True).value_in_unit(u.kilojoule_per_mole/u.nanometer)
    return np.array(forces), state.getPotentialEnergy().value_in_unit(u.kilojoule_per_mole)


def context(system, platform, props):
    return mm.Context(system, mm.VerletIntegrator(0.001), mm.Platform.getPlatformByName(platform), props)


failed = False
with open(out_path, "w") as out:
    header = (f"{'test':10} {'atoms':>6} {'precision':>9} {'rel|dF|':>10} {'max|dF|':>10} {'rel|dE|':>10} "
              f"{'repeats':>10} {'seconds':>8}")
    print(header, file=out, flush=True)
    print(header, flush=True)
    for test in tests:
        system, positions, _ = retrieveTestSystem(test)
        t0 = time.time()
        fref, eref = evaluate(context(system, "Reference", {}), positions)
        print(f"{test} Reference {time.time() - t0:.1f} s", flush=True)
        for precision in PRECISIONS:
            t0 = time.time()
            props = {"Precision": precision, "DeterministicForces": "true"}
            first = context(system, "Metal", props)
            f1, e1 = evaluate(first, positions)
            f2, e2 = evaluate(first, positions)
            del first
            f3, e3 = evaluate(context(system, "Metal", props), positions)
            identical = np.array_equal(f1, f2) and np.array_equal(f1, f3) and e1 == e2 == e3
            failed = failed or not identical
            row = (f"{test:10} {system.getNumParticles():6d} {precision:>9} "
                   f"{np.linalg.norm(f1-fref)/np.linalg.norm(fref):10.3e} {np.abs(f1-fref).max():10.3e} "
                   f"{abs(e1-eref)/abs(eref):10.3e} {'identical' if identical else 'DIFFER':>10} {time.time() - t0:8.1f}")
            if not identical:
                row += f"  max|dF| between repeats {max(np.abs(f1-f2).max(), np.abs(f1-f3).max()):.3e}"
            print(row, file=out, flush=True)
            print(row, flush=True)
sys.exit(1 if failed else 0)

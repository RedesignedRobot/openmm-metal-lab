"""Metal forces with DeterministicForces from fresh contexts, saved for bitwise comparison between builds.
Each context builds its own neighbor list, so tile order in the list differs between runs.
usage: python bitcheck.py <outdir> <runs>          (dump, run by each build's venv)
       python bitcheck.py --compare <dirA> <dirB>   (CPU only)"""
import os
import sys

import numpy as np

TESTS = ["gbsa", "rf", "pme", "apoa1rf", "apoa1pme"]
PRECISIONS = ["single", "mixed"]

if sys.argv[1] == "--compare":
    a, b = sys.argv[2], sys.argv[3]
    ok = True
    for test in TESTS:
        for precision in PRECISIONS:
            runs = sorted(f for f in os.listdir(b) if f.startswith(f"{test}-{precision}-"))
            ref = np.load(os.path.join(a, runs[0]))["forces"]
            same = [np.array_equal(np.load(os.path.join(b, r))["forces"], ref) for r in runs]
            within = all(np.array_equal(np.load(os.path.join(a, r))["forces"], ref) for r in sorted(f for f in os.listdir(a) if f.startswith(f"{test}-{precision}-")))
            print(f"{test:9} {precision:6} A runs identical: {within}  B runs equal to A: {sum(same)}/{len(same)}")
            ok = ok and within and all(same)
    print("BITWISE PASS" if ok else "BITWISE FAIL")
    sys.exit(0 if ok else 1)

import openmm as mm
import openmm.unit as u

out, runs = os.path.abspath(sys.argv[1]), int(sys.argv[2])
os.makedirs(out, exist_ok=True)
os.chdir("/tmp/openmm-metal-bench/ultra-base/benchmarks")
source = open("benchmark.py").read()
exec(source[:source.index("def serializeTest")])
for test in TESTS:
    system, positions, _ = retrieveTestSystem(test)
    for precision in PRECISIONS:
        for run in range(runs):
            context = mm.Context(system, mm.VerletIntegrator(0.001), mm.Platform.getPlatformByName("Metal"),
                                 {"Precision": precision, "DeterministicForces": "true"})
            context.setPositions(positions)
            forces = context.getState(getForces=True).getForces(asNumpy=True).value_in_unit(u.kilojoule_per_mole/u.nanometer)
            np.savez(os.path.join(out, f"{test}-{precision}-{run}.npz"), forces=np.array(forces))
            del context
        print(test, precision, "done", flush=True)

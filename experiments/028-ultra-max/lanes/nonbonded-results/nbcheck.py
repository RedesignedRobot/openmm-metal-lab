"""Forces and energy of Metal under several knob settings against Reference, for benchmark.py systems.
The knobs are environment variables the screening build reads at context creation, so one process can
try them all. usage: python nbcheck.py <tests> <precision> <label=VAR=v+VAR=v> ...  ("base=" for none)"""
import os
import sys

import numpy as np
import openmm as mm
import openmm.unit as u

os.chdir("/tmp/openmm-metal-bench/ultra-base/benchmarks")
source = open("benchmark.py").read()
exec(source[:source.index("def serializeTest")])
tests, precision = sys.argv[1].split(","), sys.argv[2]
variants = [(v.split("=", 1)[0], v.split("=", 1)[1]) for v in sys.argv[3:]]
KNOBS = ["NB_BPC", "NB_TGS", "NB_FBG", "NB_LARGE", "NB_TILES", "NB_TILES_LIM", "NB_TILES_SMALL", "NB_PAD", "NB_BITS", "NB_DEFS"]


def run(system, positions, platform, props):
    context = mm.Context(system, mm.VerletIntegrator(0.001), mm.Platform.getPlatformByName(platform), props)
    context.setPositions(positions)
    state = context.getState(getForces=True, getEnergy=True)
    return np.array(state.getForces(asNumpy=True).value_in_unit(u.kilojoule_per_mole/u.nanometer)), \
        state.getPotentialEnergy().value_in_unit(u.kilojoule_per_mole)


print(f"{'test':12} {'variant':10} {'rel|dF|':>10} {'max|dF|':>10} {'rel|dE|':>10}", flush=True)
for test in tests:
    system, positions, _ = retrieveTestSystem(test)
    fref, eref = run(system, positions, "Reference", {})
    for label, settings in variants:
        for k in KNOBS:
            os.environ.pop(k, None)
        for item in filter(None, settings.split("+")):
            k, v = item.split("=", 1)
            os.environ[k] = v
        f, e = run(system, positions, "Metal", {"Precision": precision})
        rel = np.linalg.norm(f-fref)/np.linalg.norm(fref)
        print(f"{test:12} {label:10} {rel:10.3e} {np.abs(f-fref).max():10.3e} {abs(e-eref)/abs(eref):10.3e}", flush=True)

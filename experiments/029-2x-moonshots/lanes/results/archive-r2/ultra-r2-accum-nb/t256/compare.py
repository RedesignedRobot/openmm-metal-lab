"""Compare the direct-group forces and energy of the base and 256-thread trees with Reference."""
import os
import sys
from pathlib import Path
import numpy as np
import openmm as mm
import openmm.unit as u

here = Path(__file__).resolve().parent
tag = sys.argv[1] if len(sys.argv) > 1 else "check"
ref_path = here/"ref-apoa1rf.npz"
if not ref_path.exists():
    os.chdir("/tmp/openmm-metal-bench/ultra-base/benchmarks")
    src = Path("benchmark.py").read_text()
    ns = {}
    exec(src[:src.index("def serializeTest")], ns)
    system, positions, _ = ns["retrieveTestSystem"]("apoa1rf")
    for f in system.getForces():
        f.setForceGroup(1 if isinstance(f, mm.NonbondedForce) else 0)
    c = mm.Context(system, mm.VerletIntegrator(0.001), mm.Platform.getPlatformByName("Reference"))
    c.setPositions(positions)
    s = c.getState(getForces=True, getEnergy=True, groups={1})
    np.savez(ref_path, forces=s.getForces(asNumpy=True).value_in_unit(u.kilojoule_per_mole/u.nanometer),
             energy=s.getPotentialEnergy().value_in_unit(u.kilojoule_per_mole))
ref = np.load(ref_path)
fr = ref["forces"]
def err(f):
    d = f-fr
    return np.linalg.norm(d)/np.linalg.norm(fr), np.abs(d).max()
for prec in ("single", "mixed"):
    runs = {k: np.load(here/f"{tag}-{k}-{prec}.npz") for k in ("int", "r", "g") if (here/f"{tag}-{k}-{prec}.npz").exists()}
    for k, r in runs.items():
        rms, mx = err(r["forces"])
        t = r["times"]*1e6
        print(f"{prec} {k}: force rel rms {rms:.3e} max {mx:.3e} vs Reference; direct kernel median {np.median(t):.1f} us min {t.min():.1f}")
    a = runs["int"]
    for name in [k for k in runs if k != "int"]:
        b = runs[name]
        d = b["forces"]-a["forces"]
        print(f"{prec} {name} vs int: force max diff {np.abs(d).max():.3e}, rel rms {np.linalg.norm(d)/np.linalg.norm(a['forces']):.3e}, positions equal {np.array_equal(a['positions'], b['positions'])}")
print("reference energy", float(ref["energy"]))

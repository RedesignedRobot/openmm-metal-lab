"""Force-only gbsa forces (no energy), so the force-only code paths run. Saves them to <out>.npy per precision.
usage: python ovcheck.py <benchmarks dir> <out prefix>"""
import os, sys
import numpy as np
import openmm as mm
import openmm.unit as u
bench, out = os.path.abspath(sys.argv[1]), sys.argv[2]
os.chdir(bench)
source = open("benchmark.py").read()
sys.argv = ["benchmark.py"]
exec(source[:source.index("def serializeTest")])
system, positions, _ = retrieveTestSystem("gbsa")
for precision in ["single", "mixed"]:
    context = mm.Context(system, mm.VerletIntegrator(0.001), mm.Platform.getPlatformByName("Metal"), {"Precision": precision, "DeterministicForces": "true"})
    context.setPositions(positions)
    f = context.getState(getForces=True).getForces(asNumpy=True).value_in_unit(u.kilojoule_per_mole/u.nanometer)
    np.save(f"{out}-{precision}.npy", np.array(f))
    del context
print("saved", out)

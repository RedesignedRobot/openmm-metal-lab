"""Sanity for the gbsa Step 0 diag arms: per arm, gbsa Metal mixed from benchmark.py's setup, 3000 steps, then the
potential energy and the worst relative HBond length error. Run once per arm with OPENMM_METAL_GBDIAG set."""
import os, sys, time
import numpy as np
import openmm as mm
import openmm.unit as unit

os.chdir("/tmp/openmm-metal-bench/ultra-base/benchmarks")
source = open("benchmark.py").read()
exec(source[:source.index("def serializeTest")])
system, positions, _ = retrieveTestSystem("gbsa")
integ = mm.LangevinMiddleIntegrator(300, 91, 0.004)
integ.setConstraintTolerance(1e-5)
ctx = mm.Context(system, integ, mm.Platform.getPlatformByName("Metal"), {"Precision": "mixed"})
ctx.setPositions(positions)
ctx.setVelocitiesToTemperature(300, 1)
integ.step(100)
ctx.getState(energy=True)
t = time.perf_counter()
integ.step(3000)
st = ctx.getState(energy=True, positions=True)
t = time.perf_counter()-t
x = st.getPositions(asNumpy=True).value_in_unit(unit.nanometer)
err = 0.0
for k in range(system.getNumConstraints()):
    i, j, dist = system.getConstraintParameters(k)
    err = max(err, abs(np.linalg.norm(x[i]-x[j])/dist.value_in_unit(unit.nanometer)-1))
print("arm %-6s  %.1f us/step  PE %.1f kJ/mol  max constraint err %.2e" % (os.environ.get("OPENMM_METAL_GBDIAG", "off"),
      1e6*t/3000, st.getPotentialEnergy().value_in_unit(unit.kilojoule_per_mole), err))

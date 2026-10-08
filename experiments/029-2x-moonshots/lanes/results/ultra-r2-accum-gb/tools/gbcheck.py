"""gbsa Metal forces and energy against the cached Reference, single and mixed, same metric as forces.py.
Also repeats each evaluation in a new Context and reports whether the forces are bitwise equal.
usage: python gbcheck.py <benchmarks dir> [test]"""
import os, sys
import numpy as np
import openmm as mm
import openmm.unit as u
bench = os.path.abspath(sys.argv[1])
test = sys.argv[2] if len(sys.argv) > 2 else "gbsa"
os.chdir(bench)
source = open("benchmark.py").read()
sys.argv = ["benchmark.py"]
exec(source[:source.index("def serializeTest")])
system, positions, _ = retrieveTestSystem(test)
ref = np.load(os.path.join(os.path.dirname(bench), "reference", f"{test}.npz"))
fref, eref = ref["forces"], float(ref["energy"])
print("openmm", mm.__file__, mm.pluginLoadedLibNames)
for precision in ["single", "mixed"]:
    results = []
    for rep in range(2):
        context = mm.Context(system, mm.VerletIntegrator(0.001), mm.Platform.getPlatformByName("Metal"), {"Precision": precision, "DeterministicForces": "true"})
        context.setPositions(positions)
        state = context.getState(getForces=True, getEnergy=True)
        f = np.array(state.getForces(asNumpy=True).value_in_unit(u.kilojoule_per_mole/u.nanometer))
        e = state.getPotentialEnergy().value_in_unit(u.kilojoule_per_mole)
        results.append((f, e))
        del context
    f, e = results[0]
    rel = np.linalg.norm(f-fref)/np.linalg.norm(fref)
    print(f"{test} {precision} rel|dF| {rel:.4e} max|dF| {np.abs(f-fref).max():.4e} rel|dE| {abs(e-eref)/abs(eref):.3e} E {e:.6f} Eref {eref:.6f} bitwise-repeat {np.array_equal(results[0][0], results[1][0])}", flush=True)

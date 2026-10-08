"""r2-pmefft check: PME reciprocal forces from the fused convolution (forces-only steps) against the VkFFT path
(the same Context with energy) and Reference.

Rows: pme and amber20-dhfr (56^3, fused), apoa1pme (98^3, too big for the fused kernels, both paths are VkFFT),
and two random triclinic charge systems with explicit grids that cover radices 2, 3, 4, 5, 7 and 8.
Only the reciprocal space group is evaluated. A row passes when the fused path's error against Reference is
no more than 1.02 times the VkFFT path's plus 1e-7. With DeterministicForces, two forces-only evaluations
must match bitwise.
usage: python pmecheck.py <benchmarks dir>
"""
import os
import sys

import numpy as np
import openmm as mm
import openmm.unit as u

os.chdir(sys.argv[1])
source = open("benchmark.py").read()
exec(source[:source.index("def serializeTest")])
KJ = u.kilojoule_per_mole/u.nanometer


def random_system(grid, seed):
    rng = np.random.default_rng(seed)
    a, b, c = mm.Vec3(4.0, 0, 0), mm.Vec3(1.2, 3.8, 0), mm.Vec3(-1.1, 1.5, 3.5)
    n = 4000
    system = mm.System()
    system.setDefaultPeriodicBoxVectors(a, b, c)
    nb = mm.NonbondedForce()
    nb.setNonbondedMethod(mm.NonbondedForce.PME)
    nb.setCutoffDistance(1.0)
    nb.setPMEParameters(3.0, *grid)
    for i in range(n):
        system.addParticle(10.0)
        nb.addParticle(1.0 if i%2 == 0 else -1.0, 0.3, 0.1)
    system.addForce(nb)
    frac = rng.random((n, 3))
    m = np.array([[a.x, a.y, a.z], [b.x, b.y, b.z], [c.x, c.y, c.z]])
    return system, (frac@m)*u.nanometer


def cases():
    for test in ("pme", "amber20-dhfr", "apoa1pme"):
        system, positions, _ = retrieveTestSystem(test)
        yield test, system, positions
    yield "tric-45x42x35", *random_system((45, 42, 35), 1)
    yield "tric-28x30x27", *random_system((28, 30, 27), 2)


def forces(context, energy):
    state = context.getState(getForces=True, getEnergy=energy, groups={1})
    return np.array(state.getForces(asNumpy=True).value_in_unit(KJ))


def rel(f, ref):
    return np.linalg.norm(f-ref)/np.linalg.norm(ref)


failed = False
for name, system, positions in cases():
    for i, f in enumerate(system.getForces()):
        f.setForceGroup(0)
        if isinstance(f, mm.NonbondedForce):
            f.setReciprocalSpaceForceGroup(1)
    ref_context = mm.Context(system, mm.VerletIntegrator(0.001), mm.Platform.getPlatformByName("Reference"))
    ref_context.setPositions(positions)
    ref = forces(ref_context, False)
    del ref_context
    for precision, deterministic in (("single", False), ("mixed", False), ("single", True)):
        props = {"Precision": precision}
        if deterministic:
            props["DeterministicForces"] = "true"
        context = mm.Context(system, mm.VerletIntegrator(0.001), mm.Platform.getPlatformByName("Metal"), props)
        context.setPositions(positions)
        grid = mm.NonbondedForce.getPMEParametersInContext(
            [f for f in system.getForces() if isinstance(f, mm.NonbondedForce)][0], context)[1:]
        fused = forces(context, False)
        vk = forces(context, True)
        again = forces(context, False)
        e_fused, e_vk, d = rel(fused, ref), rel(vk, ref), rel(fused, vk)
        ok = e_fused <= 1.02*e_vk+1e-7
        if deterministic:
            ok = ok and np.array_equal(fused, again)
        failed = failed or not ok
        label = precision+("+det" if deterministic else "")
        print(f"{name:16s} {label:11s} grid {grid[0]}x{grid[1]}x{grid[2]}  fused/ref {e_fused:.3e}  vkfft/ref {e_vk:.3e}  "
              f"fused/vkfft {d:.3e}  repeat-bitwise {np.array_equal(fused, again)}  {'ok' if ok else 'FAIL'}", flush=True)
        del context
print("FAIL" if failed else "PASS")
sys.exit(1 if failed else 0)

"""GayBerneForce energy and forces on OpenCL and Metal against Reference, for 20 random ellipsoids."""
import numpy as np
import openmm as mm

rng = np.random.default_rng(1)

def gay_berne():
    system = mm.System()
    gb = mm.GayBerneForce()
    n = 60
    for i in range(n):
        system.addParticle(1.0)
    for i in range(0, n, 3):
        # Each ellipsoid's axes are defined by two neighbouring particles.
        gb.addParticle(0.3, 1.0, i+1, i+2, 0.3, 0.2, 0.1, 1.0, 0.8, 0.6)
        gb.addParticle(0, 0, -1, -1, 1, 1, 1, 1, 1, 1)
        gb.addParticle(0, 0, -1, -1, 1, 1, 1, 1, 1, 1)
    system.addForce(gb)
    pos = []
    for i in range(0, n, 3):
        c = rng.uniform(0, 2.0, 3)
        pos += [c, c+[0.1, 0, 0], c+[0, 0.1, 0]]
    return system, np.array(pos)

system, pos = gay_berne()
ref = None
for name in ("Reference", "OpenCL", "Metal"):
    ctx = mm.Context(system, mm.VerletIntegrator(0.001), mm.Platform.getPlatformByName(name))
    ctx.setPositions(pos)
    s = ctx.getState(getForces=True, getEnergy=True)
    f = s.getForces(asNumpy=True)._value
    e = s.getPotentialEnergy()._value
    if ref is None:
        ref = (f, e)
    print("GayBerne", name, "energy", e, "rel force err", np.linalg.norm(f-ref[0])/np.linalg.norm(ref[0]))

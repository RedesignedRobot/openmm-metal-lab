# Max position error after setPositions reorders 64 particles that start outside the box (the C++ test's setup).
import sys, numpy as np, openmm as mm
width = 7.3
system = mm.System()
system.setDefaultPeriodicBoxVectors(mm.Vec3(width, 0, 0), mm.Vec3(0, width, 0), mm.Vec3(0, 0, width))
nb = mm.NonbondedForce(); nb.setNonbondedMethod(mm.NonbondedForce.CutoffPeriodic); nb.setCutoffDistance(1.0)
system.addForce(nb)
rng = np.random.default_rng(0)
pos = np.column_stack([-0.5*rng.random(64), width+0.5*rng.random(64), width*rng.random(64)])
for p in pos:
    system.addParticle(1.0); nb.addParticle(0.0, 0.3, 0.0)
c = mm.Context(system, mm.VerletIntegrator(0.001), mm.Platform.getPlatformByName('Metal'), {'Precision': sys.argv[1]})
c.setPositions(pos)
found = c.getState(getPositions=True).getPositions(asNumpy=True)._value
print(f"{sys.argv[2]} {sys.argv[1]}: max |dx| after wrap {np.abs(found-pos).max():.2e} nm", flush=True)

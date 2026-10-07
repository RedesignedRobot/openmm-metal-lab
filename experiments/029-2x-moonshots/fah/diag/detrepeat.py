# Is DeterministicForces run-to-run bitwise at all?  Two fresh Contexts from one checkpoint, and one Context
# replaying the same checkpoint twice.  Barostat removed.
import bz2, sys, numpy as np, openmm as mm
wu, precision = sys.argv[1], sys.argv[2]
ld = lambda n: mm.XmlSerializer.deserialize(bz2.open(f'{wu}/{n}.xml.bz2','rt').read())
system, state = ld('system'), ld('state')
for i in reversed(range(system.getNumForces())):
    if isinstance(system.getForce(i), mm.MonteCarloBarostat): system.removeForce(i)
props = {'Precision': precision, 'DeterministicForces': 'true'}
def fresh():
    integ = ld('integrator'); integ.setRandomNumberSeed(2026)
    return integ, mm.Context(system, integ, mm.Platform.getPlatformByName('Metal'), props)
integ, c = fresh()
c.setPeriodicBoxVectors(*state.getPeriodicBoxVectors()); c.setPositions(state.getPositions()); c.setVelocities(state.getVelocities())
integ.step(300)
chk = c.createCheckpoint()
def run(ctx, it, n):
    ctx.loadCheckpoint(chk)
    f0 = ctx.getState(getForces=True).getForces(asNumpy=True)._value
    it.step(n)
    return f0, ctx.getState(getPositions=True).getPositions(asNumpy=True)._value
fa, xa = run(c, integ, 200); fb, xb = run(c, integ, 200)
i2, c2 = fresh(); fc, xc = run(c2, i2, 200)
i3, c3 = fresh(); fd, xd = run(c3, i3, 200)
name = wu.split('/')[-1]
print(f'{name} {precision} same ctx replay: dF0 {np.abs(fa-fb).max():.3g} dx {np.abs(xa-xb).max():.3g} | '
      f'orig vs fresh: dF0 {np.abs(fa-fc).max():.3g} dx {np.abs(xa-xc).max():.3g} | '
      f'fresh vs fresh: dF0 {np.abs(fc-fd).max():.3g} dx {np.abs(xc-xd).max():.3g}', flush=True)

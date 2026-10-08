# Does a deterministic binary-checkpoint continuation match bit for bit once the original Context also rebuilds
# its neighbor list at the checkpoint?  Barostat removed.
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
for rebuild in [False, True]:
    integ, c = fresh()
    c.setPeriodicBoxVectors(*state.getPeriodicBoxVectors()); c.setPositions(state.getPositions()); c.setVelocities(state.getVelocities())
    integ.step(300)
    chk = c.createCheckpoint()
    if rebuild:
        c.loadCheckpoint(chk)
    integ.step(200)
    x = c.getState(getPositions=True).getPositions(asNumpy=True)._value
    integ2, c2 = fresh(); c2.loadCheckpoint(chk); integ2.step(200)
    x2 = c2.getState(getPositions=True).getPositions(asNumpy=True)._value
    print(f'{wu.split("/")[-1]} {precision} original reloads its own checkpoint: {rebuild}  max|dx| after 200 steps {np.abs(x-x2).max():.3g}', flush=True)

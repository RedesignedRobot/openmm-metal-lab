# Per-step constraint error in mixed with and without the barostat: does the error follow the barostat or the 250-step reorder?
import bz2, sys, numpy as np, openmm as mm
sys.path.insert(0, '..'); sys.path.insert(0, '.')
from wu import constraint_error
wu, baro, seed, steps = sys.argv[1], sys.argv[2] == 'baro', int(sys.argv[3]), int(sys.argv[4])
ld = lambda n: mm.XmlSerializer.deserialize(bz2.open(f'{wu}/{n}.xml.bz2','rt').read())
system, integ, state = ld('system'), ld('integrator'), ld('state')
for i in reversed(range(system.getNumForces())):
    f = system.getForce(i)
    if isinstance(f, mm.MonteCarloBarostat):
        if baro: f.setRandomNumberSeed(seed)
        else: system.removeForce(i)
integ.setRandomNumberSeed(seed)
c = mm.Context(system, integ, mm.Platform.getPlatformByName('Metal'), {'Precision': 'mixed'})
if baro: c.setState(state)
else:
    c.setPeriodicBoxVectors(*state.getPeriodicBoxVectors())
    c.setPositions(state.getPositions())
    c.setVelocities(state.getVelocities())
bad = []
for k in range(1, steps+1):
    integ.step(1)
    s = c.getState(getPositions=True)
    err = constraint_error(system, s.getPositions(asNumpy=True)._value, s.getPeriodicBoxVectors(asNumpy=True)._value)
    if err > 1e-6: bad.append(f"{k}:{err:.1e}")
print(f"{'baro' if baro else 'nobaro'} seed {seed} steps {steps}: over 1e-6 at {' '.join(bad) or 'none'}", flush=True)

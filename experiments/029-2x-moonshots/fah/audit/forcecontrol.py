# Force expressions evaluate in float even in mixed, so the eleven functions must work there.
import openmm as mm, numpy as np
s = mm.System(); [s.addParticle(1.0) for _ in range(64)]
nb = mm.CustomNonbondedForce('1e-3*(erfc(r)+erf(r)*tanh(r)+atan(r)+asin(0.1*r)+acos(0.1*r)+tan(0.1*r)+sinh(r)+cosh(r)+atan2(r,1)+r^1.5)')
[nb.addParticle([]) for _ in range(64)]; s.addForce(nb)
b = mm.CustomBondForce('1e-3*(erfc(r)+tanh(r)+r^2.5)'); b.addBond(0, 1, []); s.addForce(b)
x = np.random.default_rng(1).random((64, 3))*2
res = {}
for name, props in (('Reference', {}), ('Metal single', {'Precision': 'single'}), ('Metal mixed', {'Precision': 'mixed'})):
    c = mm.Context(s, mm.VerletIntegrator(0.001), mm.Platform.getPlatformByName(name.split()[0]), props); c.setPositions(x)
    st = c.getState(getEnergy=True, getForces=True); res[name] = (st.getPotentialEnergy()._value, st.getForces(asNumpy=True)._value)
for name in ('Metal single', 'Metal mixed'):
    print('forces with all eleven functions, %s: dE %.2e max|dF| %.2e' % (name, res[name][0]-res['Reference'][0], np.abs(res[name][1]-res['Reference'][1]).max()))

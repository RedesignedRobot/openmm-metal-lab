"""Cross-check the bridge's combined mesh force with a Reference Context."""
import json
import math
import numpy as np
import openmm as mm
from openmm import unit as u
from analyze import ROOT, Reference, ALPHA, day_only

day_only()
data = np.load(ROOT/'apoa1ljpme-input.npz')
system = mm.System()
nb = mm.NonbondedForce()
nb.setNonbondedMethod(mm.NonbondedForce.LJPME)
nb.setCutoffDistance(0.9)
nb.setIncludeDirectSpace(False)
nb.setPMEParameters(ALPHA, 98, 98, 98)
nb.setLJPMEParameters(ALPHA, 49, 49, 49)
system.setDefaultPeriodicBoxVectors(*data['box'])
for q, c6 in zip(data['charge'], data['c6']):
    system.addParticle(1)
    nb.addParticle(q, 1, (c6/2)**2)
system.addForce(nb)
integrator = mm.VerletIntegrator(0.002)
context = mm.Context(system, integrator, mm.Platform.getPlatformByName('Reference'))
context.setPositions(data['xyz'][0])
state = context.getState(forces=True, energy=True)
target = state.getForces(asNumpy=True).value_in_unit(u.kilojoule_per_mole/u.nanometer)
engine = Reference()
fc, ec = engine(data['xyz'][0], data['charge'], data['box'], 5, (98,)*3)
fd, ed = engine(data['xyz'][0], data['c6'], data['box'], 5, (49,)*3, True)
relative = float(np.linalg.norm(fc+fd-target)/np.linalg.norm(target))
assert relative < 1e-12, relative
self_energy = (-138.93545764438198*ALPHA/math.sqrt(math.pi)*np.sum(data['charge']**2)
               +ALPHA**6/12*np.sum(data['c6']**2))
background = (-138.93545764438198*math.pi*np.sum(data['charge'])**2
              /(2*ALPHA**2*np.linalg.det(data['box'])))
energy_delta = ec+ed+self_energy+background-state.getPotentialEnergy().value_in_unit(u.kilojoule_per_mole)
# The Context sums self terms serially over 92,224 atoms; numpy uses a
# different reduction. Check the cancellation of these large constants.
assert abs(energy_delta) < 1e-4, energy_delta
result = {'reference_context_relative_force_difference': relative,
          'energy_difference_including_self_terms': energy_delta,
          'atoms': len(target), 'alpha': ALPHA,
          'coulomb_grid': [98]*3, 'dispersion_grid': [49]*3}
(ROOT/'lj-context-validation.json').write_text(json.dumps(result, indent=2)+'\n')
print(json.dumps(result))

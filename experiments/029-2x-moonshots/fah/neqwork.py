"""Protocol work distribution of the neq work unit: one full forward-reverse cycle (2*n_steps) per seed.
    python neqwork.py <wu dir> <platform> <precision|-> <first seed> <count>"""
import bz2, sys, os, numpy as np, openmm as mm
wu, platform, precision, first, count = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5])
ld = lambda n: mm.XmlSerializer.deserialize(bz2.open(os.path.join(wu, n + '.xml.bz2'), 'rt').read())
system, state, xml = ld('system'), ld('state'), mm.XmlSerializer.serialize(ld('integrator'))
props = {'Precision': precision} if precision != '-' else {'Threads': '8'} if platform == 'CPU' else {}
works = []
for seed in range(first, first + count):
    integrator = mm.XmlSerializer.deserialize(xml)
    integrator.setRandomNumberSeed(seed)
    context = mm.Context(system, integrator, mm.Platform.getPlatformByName(platform), props)
    context.setState(state)
    context.setVelocitiesToTemperature(300, seed)
    integrator.step(2*int(integrator.getGlobalVariableByName('n_steps')))
    works.append(integrator.getGlobalVariableByName('protocol_work'))
    del context
w = np.array(works)
print('%s %s: n %d work mean %.1f median %.1f sd %.1f min %.1f max %.1f kJ/mol  %s' % (
    platform, precision, len(w), w.mean(), np.median(w), w.std(ddof=1), w.min(), w.max(), ' '.join('%.0f' % x for x in w)), flush=True)

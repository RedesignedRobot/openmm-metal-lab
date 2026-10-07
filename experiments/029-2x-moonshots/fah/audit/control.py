# Negative control: an integrator that uses tanh and x^1.5 per DOF must be flagged by audit.py and rejected by Metal mixed.
import bz2, sys, openmm as mm
sys.path.insert(0, sys.argv[2]); import audit
i = mm.CustomIntegrator(0.001); i.addComputePerDof('v', 'v + dt*f/m + 0.001*tanh(v)'); i.addComputePerDof('x', 'x + dt*v*abs(v)^1.5')
audit.audit('control (tanh, ^1.5)', i)
if len(sys.argv) > 3:
    system = mm.XmlSerializer.deserialize(bz2.open(sys.argv[1] + '/system.xml.bz2', 'rt').read())
    state = mm.XmlSerializer.deserialize(bz2.open(sys.argv[1] + '/state.xml.bz2', 'rt').read())
    for p in ('single', 'mixed'):
        try:
            c = mm.Context(system, i, mm.Platform.getPlatformByName('Metal'), {'Precision': p}); c.setState(state); i.step(2); print('    Metal %s: ran' % p); del c
        except Exception as e:
            print('    Metal %s: rejected: %s' % (p, str(e).splitlines()[0][:100]))
        i = mm.XmlSerializer.deserialize(mm.XmlSerializer.serialize(i))

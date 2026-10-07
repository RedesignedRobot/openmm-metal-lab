# Constraint error right after each barostat attempt in mixed: does an accepted move leave float-level error?
import bz2, sys, numpy as np, openmm as mm
sys.path.insert(0, '..'); sys.path.insert(0, '.')
from wu import constraint_error
wu, precision, seed = sys.argv[1], sys.argv[2], int(sys.argv[3])
ld = lambda n: mm.XmlSerializer.deserialize(bz2.open(f'{wu}/{n}.xml.bz2','rt').read())
system, integ, state = ld('system'), ld('integrator'), ld('state')
integ.setRandomNumberSeed(seed)
for f in system.getForces():
    if isinstance(f, mm.MonteCarloBarostat): f.setRandomNumberSeed(seed)
c = mm.Context(system, integ, mm.Platform.getPlatformByName('Metal'), {'Precision': precision})
c.setState(state)
vol = None; rows = []
for k in range(1, 41):
    integ.step(25)
    s = c.getState(getPositions=True)
    box = s.getPeriodicBoxVectors(asNumpy=True)._value
    v = float(np.linalg.det(box))
    err = constraint_error(system, s.getPositions(asNumpy=True)._value, box)
    rows.append((k*25, v != vol, err)); vol = v
acc = [e for _, a, e in rows[1:] if a]; rej = [e for _, a, e in rows[1:] if not a]
print(f"{wu.split(chr(47))[-1]} {precision} seed {seed}: " + " ".join(f"{s}:{"acc" if a else "rej"}:{e:.1e}" for s, a, e in rows if s % 250 == 0 or e > 1e-6), flush=True)

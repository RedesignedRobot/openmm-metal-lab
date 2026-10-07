"""Check joint Coulomb/dispersion errors, including a split-order diagnostic."""
import json
import numpy as np
from analyze import ROOT, Reference, errors
from cost import lj_saving

engine = Reference()
data = np.load(ROOT/'apoa1ljpme-input.npz')
rows = []
for frame, xyz in enumerate(data['xyz']):
    rc = np.load(ROOT/f'apoa1ljpme-coulomb-{frame}-reference.npz')
    rd = np.load(ROOT/f'apoa1ljpme-dispersion-{frame}-reference.npz')
    ref = rc['forces']+rd['forces']
    eref = float(rc['energy']+rd['energy'])
    for oc, gc, od, gd in [(5, 98, 5, 49), (4, 160, 4, 63), (5, 98, 4, 63)]:
        fc, ec = engine(xyz, data['charge'], data['box'], oc, (gc,)*3)
        fd, ed = engine(xyz, data['c6'], data['box'], od, (gd,)*3, True)
        row = {'test': 'apoa1ljpme', 'frame': frame,
               'coulomb_order': oc, 'coulomb_grid': [gc]*3,
               'dispersion_order': od, 'dispersion_grid': [gd]*3,
               'saving_us': lj_saving(oc, (gc,)*3, od, (gd,)*3),
               **errors(fc+fd, ec+ed, ref, eref)}
        rows.append(row)
        print(json.dumps(row), flush=True)
(ROOT/'lj-combined.json').write_text(json.dumps(rows, indent=2)+'\n')

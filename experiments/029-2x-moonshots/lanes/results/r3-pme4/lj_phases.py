"""Additional mesh-phase configurations for the LJPME accuracy screen."""
import json
import numpy as np
from analyze import ROOT, Reference, errors
from cost import lj_saving

data = np.load(ROOT/'apoa1ljpme-input.npz')
engine = Reference()
rng = np.random.default_rng(290927)
rows = []
for frame, xyz in enumerate(data['xyz']):
    for phase in range(3):
        # Rigid translation changes mesh alignment, not the exact force.
        shift = rng.random(3)*np.diag(data['box'])/49
        x = xyz+shift
        fc, ec = engine(x, data['charge'], data['box'], 8, (196,)*3)
        fd, ed = engine(x, data['c6'], data['box'], 8, (98,)*3, True)
        ref, eref = fc+fd, ec+ed
        baseline = None
        for order, cg, dg in [(5, 98, 49), (4, 96, 49), (4, 96, 50), (4, 98, 49), (4, 100, 49)]:
            fc, ec = engine(x, data['charge'], data['box'], order, (cg,)*3)
            fd, ed = engine(x, data['c6'], data['box'], order, (dg,)*3, True)
            error = errors(fc+fd, ec+ed, ref, eref)
            if order == 5:
                baseline = error
            row = dict(frame=frame, phase=phase, shift_nm=shift.tolist(), order=order,
                       coulomb_grid=[cg]*3, dispersion_grid=[dg]*3,
                       saving_us=lj_saving(order, (cg,)*3, order, (dg,)*3),
                       ratios={k:error[k]/baseline[k] for k in
                               ('rms_relative', 'max_relative', 'max_atom_relative')},
                       **error)
            rows.append(row)
            print(json.dumps(row), flush=True)
(ROOT/'lj-phases.json').write_text(json.dumps(rows, indent=2)+'\n')

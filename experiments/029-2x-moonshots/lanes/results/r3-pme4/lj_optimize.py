"""Optimize the combined LJPME force error, not separate error budgets.

Search legal cubic Coulomb dimensions 52..176 and dispersion 26..91,
orders 4 and 5. Check every more-profitable pair before accepting one.
The common-order policy and independent-order policy are reported separately.
"""
import json
import numpy as np
from analyze import ROOT, Reference, errors, legal
from cost import lj_saving

engine = Reference()
data = np.load(ROOT/'apoa1ljpme-input.npz')
configurations = list(data['xyz'])
rng = np.random.default_rng(290927)
for xyz in data['xyz']:
    for _ in range(3):
        configurations.append(xyz+rng.random(3)*np.diag(data['box'])/49)
refs = []
baselines = []
cache = {}


def evaluate(frame, channel, order, size):
    key = frame, channel, order, size
    if key not in cache:
        cache[key] = engine(configurations[frame], data['charge' if channel == 'c' else 'c6'],
                            data['box'], order, (size,)*3, channel == 'd')
    return cache[key]


for frame, xyz in enumerate(configurations):
    if frame < 3:
        rc = np.load(ROOT/f'apoa1ljpme-coulomb-{frame}-reference.npz')
        rd = np.load(ROOT/f'apoa1ljpme-dispersion-{frame}-reference.npz')
        refs.append((rc['forces']+rd['forces'], float(rc['energy']+rd['energy'])))
    else:
        fc, ec = engine(xyz, data['charge'], data['box'], 8, (196,)*3)
        fd, ed = engine(xyz, data['c6'], data['box'], 8, (98,)*3, True)
        refs.append((fc+fd, ec+ed))
    fc, ec = evaluate(frame, 'c', 5, 98)
    fd, ed = evaluate(frame, 'd', 5, 49)
    baselines.append(errors(fc+fd, ec+ed, *refs[frame]))

pairs = []
for oc in (4, 5):
    for od in (4, 5):
        for gc in range(52, 177):
            if legal(gc) != gc:
                continue
            for gd in range(26, 92):
                if legal(gd) != gd:
                    continue
                gain = lj_saving(oc, (gc,)*3, od, (gd,)*3)
                if gain > 0:
                    pairs.append((gain, oc, gc, od, gd))
pairs.sort(reverse=True)
best_common = None
best_any = None
checked = []
for gain, oc, gc, od, gd in pairs:
    if best_any is not None and (oc != od or best_common is not None):
        continue
    rows = []
    passed = True
    for frame in range(len(configurations)):
        fc, ec = evaluate(frame, 'c', oc, gc)
        fd, ed = evaluate(frame, 'd', od, gd)
        row = errors(fc+fd, ec+ed, *refs[frame])
        rows.append(row)
        if any(row[k] > baselines[frame][k]
               for k in ('rms_relative', 'max_relative', 'max_atom_relative')):
            passed = False
            break
    record = dict(saving_us=gain, coulomb_order=oc, coulomb_grid=[gc]*3,
                  dispersion_order=od, dispersion_grid=[gd]*3,
                  passed=passed, errors=rows)
    checked.append(record)
    if passed:
        if best_any is None:
            best_any = record
        if oc == od:
            best_common = record
        print(json.dumps(record), flush=True)
    if best_any is not None and best_common is not None:
        break
result = dict(baseline=baselines, best_common_order=best_common,
              best_independent_orders=best_any, candidates_in_cost_order=checked,
              positive_cost_candidates=len(pairs), reference_evaluations=len(cache),
              configurations=len(configurations), phase_seed=290927)
(ROOT/'lj-optimum.json').write_text(json.dumps(result, indent=2)+'\n')
print(json.dumps({'checked': len(checked), 'reference_evaluations': len(cache)}), flush=True)

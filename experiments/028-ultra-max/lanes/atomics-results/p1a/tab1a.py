"""Per-kernel table for probe 1a: us per force evaluation of computeBondedForces, computeNonbonded and foldForceWords
per test and variant, plus the unprofiled step (mean of windows A and C, host clock). Drops and speedups are against base."""
import json, sys, os
O = sys.argv[1]
names = {'prof': 'base', 'prof-lo': '1 atomic', 'prof-plain': 'plain', 'prof-words': 'words'}
tests = {'apoa1rf': list(names), 'rf': list(names), 'apoa1pme': list(names), 'amber20-cellulose': list(names),
         'gbsa': ['prof', 'prof-words'], 'pme': ['prof', 'prof-words']}
def load(tag):
    path = os.path.join(O, tag + '.sum')
    if not os.path.exists(path):
        return None
    for line in open(path):
        if line.startswith('json '):
            return json.loads(line[5:])
    return None
def kernel_us(d, prefix):
    return sum(v['us'] for name, v in (d.get('kernels') or {}).items() if name.startswith(prefix))
print('| test | row | ' + ' | '.join(names.values()) + ' | ' + ' | '.join(f'vs base: {n}' for n in list(names.values())[1:]) + ' |')
print('|---|---|' + '---:|'*(2*len(names)-1))
for t, variants in tests.items():
    ds = {v: load(f'{t}-{v}') for v in variants}
    missing = [v for v, d in ds.items() if d is None]
    if missing:
        print(f'| {t} | missing: {" ".join(missing)} |')
        continue
    def row(label, value, fmt, compare):
        vals = {v: value(ds[v]) for v in variants}
        cells = [f'{vals[v]:{fmt}}' if v in vals else '' for v in names]
        base = vals['prof']
        rel = [compare(base, vals[v]) if v in vals and base else '' for v in list(names)[1:]]
        print(f'| {t} | {label} | ' + ' | '.join(cells) + ' | ' + ' | '.join(rel) + ' |')
    drop = lambda b, x: f'{1-x/b:+.0%} drop'
    for prefix in ('computeBondedForces', 'computeNonbonded', 'foldForceWords'):
        row(prefix, lambda d: kernel_us(d, prefix), '.1f', drop)
    row('GPU busy', lambda d: d['busy_us'], '.1f', drop)
    row('step (A,C)', lambda d: sum(d['unprofiled_us'])/2, '.1f', lambda b, x: f'{b/x:.3f}x')

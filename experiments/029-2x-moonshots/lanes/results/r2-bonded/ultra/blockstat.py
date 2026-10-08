"""Bonded work and 64-bit atomic adds per layout. CPU only, no Context is created.

today: chunked per force (64 terms, original order) for forces with >= 10000 terms, per-term atomics below.
block B: a threadgroup owns B contiguous atoms; it evaluates every term touching an owned atom (terms that
cross blocks run once per block they touch), reduces owned-atom forces in registers, one add per owned atom
that has any term.
"""
import sys, os
import numpy as np
bench = '/tmp/openmm-metal-bench/ultra-base/benchmarks/benchmark.py'
os.chdir('/tmp/openmm-metal-bench/ultra-base/benchmarks')
src = open(bench).read()
g = {'__name__': 'blockstat'}
exec(compile(src[:src.index('def serializeTest')], bench, 'exec'), g)
import openmm as mm

def terms(system, pme):
    out = {}
    for f in system.getForces():
        if isinstance(f, mm.HarmonicBondForce) and f.getNumBonds() > 0:
            out['bonds'] = np.array([f.getBondParameters(i)[:2] for i in range(f.getNumBonds())])
        elif isinstance(f, mm.HarmonicAngleForce) and f.getNumAngles() > 0:
            out['angles'] = np.array([f.getAngleParameters(i)[:3] for i in range(f.getNumAngles())])
        elif isinstance(f, mm.PeriodicTorsionForce) and f.getNumTorsions() > 0:
            out['torsions'] = np.array([f.getTorsionParameters(i)[:4] for i in range(f.getNumTorsions())])
        elif isinstance(f, mm.RBTorsionForce) and f.getNumTorsions() > 0:
            out['rbtorsions'] = np.array([f.getTorsionParameters(i)[:4] for i in range(f.getNumTorsions())])
        elif isinstance(f, mm.CMAPTorsionForce) and f.getNumTorsions() > 0:
            out['cmap'] = np.array([f.getTorsionParameters(i)[1:9] for i in range(f.getNumTorsions())])
        elif isinstance(f, mm.NonbondedForce):
            ex = [f.getExceptionParameters(i) for i in range(f.getNumExceptions())]
            nz = [e[:2] for e in ex if e[2]._value != 0 or e[4]._value != 0]
            if nz:
                out['exceptions'] = np.array(nz)
            if pme and ex:
                out['exclusions'] = np.array([e[:2] for e in ex])
        elif f.__class__.__name__ not in ('CMMotionRemover', 'NonbondedForce', 'MonteCarloBarostat'):
            print('  other force', f.__class__.__name__)
    return out

def today(t):
    adds = 0
    for name, a in t.items():
        n, k = a.shape
        if n < 10000 or k > 4:
            adds += n*k
            continue
        for c in range(0, n, 64):
            adds += len(np.unique(a[c:c+64]))
    return adds

def block(t, natoms, B):
    nblocks = (natoms+B-1)//B
    evals = chunks = 0
    touched = np.zeros(natoms, bool)
    perforce = {}
    for name, a in t.items():
        n, k = a.shape
        touched[a.ravel()] = True
        # blocks each term touches
        b = a//B
        cnt = np.zeros(nblocks, np.int64)
        for j in range(k):
            first = np.ones(n, bool)
            for i in range(j):
                first &= b[:, j] != b[:, i]
            np.add.at(cnt, b[first, j], 1)
        e = int(cnt.sum())
        ch = int(np.ceil(cnt/64).sum())
        evals += e
        chunks += ch
        perforce[name] = (n, e/n, ch)
    return evals, chunks, int(touched.sum()), perforce

for test in sys.argv[1:]:
    system = g['retrieveTestSystem'](test)[0]
    natoms = system.getNumParticles()
    t = terms(system, 'pme' in test or 'cellulose' in test or 'stmv' in test or 'dhfr' in test)
    nterms = sum(len(a) for a in t.values())
    slots = sum(a.size for a in t.values())
    ta = today(t)
    print(f'{test} atoms {natoms} terms {nterms} slots {slots} | today adds/comp {ta} ({slots/ta:.2f}x vs per-term)')
    for name, a in t.items():
        print(f'    {name:10s} {len(a):8d} x {a.shape[1]}')
    for B in (64, 128, 256):
        e, ch, touched, pf = block(t, natoms, B)
        print(f'  B={B:3d}: evals {e} ({e/nterms:.3f}x terms), chunks {ch}, lane use {e/(64*ch):.2f}, adds/comp {touched} ({ta/touched:.2f}x fewer than today)')
        print('     ' + ', '.join(f'{k} dup {v[1]:.3f}' for k, v in pf.items()))
    sys.stdout.flush()

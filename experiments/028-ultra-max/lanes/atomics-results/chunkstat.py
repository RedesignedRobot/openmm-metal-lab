"""Count bonded atomic adds per chunk layout. CPU only, no Context is created."""
import sys, os
bench = '/tmp/openmm-metal-bench/ultra-base/benchmarks/benchmark.py'
os.chdir('/tmp/openmm-metal-bench/ultra-base/benchmarks')
src = open(bench).read()
g = {'__name__': 'chunkstat'}
exec(compile(src[:src.index('def serializeTest')], bench, 'exec'), g)
import openmm as mm
tests = sys.argv[1:]

def terms(system, pme):
    out = {}
    for f in system.getForces():
        if isinstance(f, mm.HarmonicBondForce):
            out['bonds'] = [f.getBondParameters(i)[:2] for i in range(f.getNumBonds())]
        elif isinstance(f, mm.HarmonicAngleForce):
            out['angles'] = [f.getAngleParameters(i)[:3] for i in range(f.getNumAngles())]
        elif isinstance(f, mm.PeriodicTorsionForce):
            out['torsions'] = [f.getTorsionParameters(i)[:4] for i in range(f.getNumTorsions())]
        elif isinstance(f, mm.NonbondedForce):
            ex = [f.getExceptionParameters(i) for i in range(f.getNumExceptions())]
            out['exceptions'] = [e[:2] for e in ex if e[2]._value != 0 or e[4]._value != 0]
            if pme:
                out['exclusions'] = [e[:2] for e in ex]
    return out

def unique(atomsList, chunk, order):
    total = 0
    for c in range(0, len(order), chunk):
        s = set()
        for i in order[c:c+chunk]:
            s.update(atomsList[i])
        total += len(s)
    return total

for test in tests:
    system = g['retrieveTestSystem'](test)[0]
    t = terms(system, 'pme' in test or 'cellulose' in test)
    print(test, system.getNumParticles(), 'atoms')
    tot = {}
    for name, a in t.items():
        slots = sum(len(x) for x in a)
        orig = list(range(len(a)))
        byOwner = sorted(orig, key=lambda i: (min(a[i]), i))
        row = [name, len(a), slots]
        for chunk in (64, 128, 256):
            u0 = unique(a, chunk, orig)
            u1 = unique(a, chunk, byOwner)
            row += [u0, u1]
            tot.setdefault(chunk, [0, 0])
            tot[chunk][0] += u0
            tot[chunk][1] += u1
        tot.setdefault('slots', 0)
        tot['slots'] += slots
        print('  %-10s terms %7d slots %8d | 64: %7d %7d | 128: %7d %7d | 256: %7d %7d' % tuple(row))
    print('  total slots %d; unique adds orig/sorted: ' % tot['slots'] + ' '.join('%d: %d %d (%.1fx %.1fx)' % (c, tot[c][0], tot[c][1], tot['slots']/tot[c][0], tot['slots']/tot[c][1]) for c in (64, 128, 256)))
    sys.stdout.flush()

"""Constraint census for a FAH work-unit corpus: SETTLE, SHAKE and CCMA counts per unit.

Mirrors IntegrationUtilities::IntegrationUtilities (platforms/common/src/IntegrationUtilities.cpp) at b995eeba8:
SETTLE takes a triangle of three constraints where two float-cast distances are equal; SHAKE takes a central
atom with up to three peripheral atoms, each peripheral in exactly one constraint, all distances and peripheral
masses equal to 1e-8, the central atom's constraints all inside the cluster; every constraint whose first atom
is in neither goes to CCMA. The Metal fused LangevinMiddle path (MetalIntegrationUtilities::integrateLangevinMiddle)
refuses the whole system when CCMA holds any constraint, so one bad cluster costs the unit the fused kernel.

Usage: python3 constraints.py <corpus dir> [unit ...]   (CPU only; needs the openmm python module)
"""
import bz2
import os
import struct
import sys
from collections import Counter, defaultdict

import openmm as mm

ELEMENT = {1: 'H', 12: 'C', 14: 'N', 16: 'O', 19: 'F', 23: 'Na', 31: 'P', 32: 'S', 35: 'Cl', 39: 'K', 80: 'Br'}


def f32(x):
    return struct.unpack('f', struct.pack('f', x))[0]


def label(mass):
    return ELEMENT.get(int(round(mass)), 'm%.2f' % mass)


def classify(system):
    n = system.getNumParticles()
    mass = [system.getParticleMass(i).value_in_unit(mm.unit.dalton) for i in range(n)]
    cons = [system.getConstraintParameters(i) for i in range(system.getNumConstraints())]
    atom1 = [c[0] for c in cons]
    atom2 = [c[1] for c in cons]
    dist = [c[2].value_in_unit(mm.unit.nanometer) for c in cons]
    count = Counter(atom1) + Counter(atom2)

    # SETTLE: atoms with exactly two constraints whose partners are constrained to each other.
    settle = [dict() for _ in range(n)]
    for a, b, d in zip(atom1, atom2, dist):
        if count[a] == 2 and count[b] == 2:
            settle[a][b] = f32(d)
            settle[b][a] = f32(d)
    is_shake = [False] * n
    settle_clusters = 0
    settle_rejected = 0
    for i in range(n):
        if len(settle[i]) != 2:
            settle[i] = {}
            continue
        p1, p2 = list(settle[i])
        if len(settle[p1]) != 2 or len(settle[p2]) != 2 or p2 not in settle[p1]:
            settle[i] = {}
            continue
        if is_shake[i]:
            continue
        d12, d13, d23 = settle[i][p1], settle[i][p2], settle[p1][p2]
        if d12 == d13 or d12 == d23 or d13 == d23:
            settle_clusters += 1
            is_shake[i] = is_shake[p1] = is_shake[p2] = True
        else:
            settle_rejected += 1

    # SHAKE: central atom plus up to three peripherals.
    clusters = {}
    invalid = [False] * n

    def mark_invalid(cid):
        c = clusters[cid]
        c['valid'] = False
        invalid[cid] = True
        for p in c['peri']:
            invalid[p] = True
            other = clusters.get(p)
            if other is not None and other['valid']:
                mark_invalid(p)

    for a, b, d in zip(atom1, atom2, dist):
        if is_shake[a]:
            continue
        if count[a] > 1:
            central, peri = a, b
        elif count[b] > 1:
            central, peri = b, a
        elif a < b:
            central, peri = a, b
        else:
            central, peri = b, a
        c = clusters.setdefault(central, {'peri': [], 'dist': None, 'pmass': None, 'valid': True})
        pm = 1.0 / mass[peri]
        if len(c['peri']) == 3 or (c['peri'] and (abs(d - c['dist']) / c['dist'] > 1e-8 or
                                                  abs(pm - c['pmass']) / c['pmass'] > 1e-8)):
            c['valid'] = False
        else:
            c['peri'].append(peri)
            c['dist'] = d
            c['pmass'] = pm
        if count[peri] != 1 or invalid[a] or invalid[b]:
            mark_invalid(central)
            other = clusters.get(peri)
            if other is not None and other['valid']:
                mark_invalid(peri)
    shake_by_size = Counter()
    for cid, c in clusters.items():
        if not c['valid']:
            continue
        c['valid'] = not invalid[cid] and len(c['peri']) == count[cid] and not any(invalid[p] for p in c['peri'])
        if c['valid']:
            shake_by_size[len(c['peri'])] += 1
            is_shake[cid] = True
            for p in c['peri']:
                is_shake[p] = True

    # CCMA: what is left, grouped into connected components.
    ccma = [i for i in range(len(cons)) if not is_shake[atom1[i]]]
    adj = defaultdict(set)
    for i in ccma:
        adj[atom1[i]].add(i)
        adj[atom2[i]].add(i)
    seen = set()
    components = []
    for i in ccma:
        if i in seen:
            continue
        stack, comp = [i], []
        seen.add(i)
        while stack:
            j = stack.pop()
            comp.append(j)
            for atom in (atom1[j], atom2[j]):
                for k in adj[atom]:
                    if k not in seen:
                        seen.add(k)
                        stack.append(k)
        bonds = Counter('%s-%s %.4f' % tuple(sorted([label(mass[atom1[j]]), label(mass[atom2[j]])]) + (dist[j],))
                        for j in comp)
        components.append((len(comp), bonds))
    free = n - sum(is_shake)
    return dict(atoms=n, constraints=len(cons), settle=settle_clusters, settle_rejected=settle_rejected,
                shake=shake_by_size, ccma=len(ccma), components=components, free=free)


def load(path):
    with bz2.open(path, 'rt') as f:
        return mm.XmlSerializer.deserialize(f.read())


def main():
    corpus = sys.argv[1]
    units = sys.argv[2:] or sorted(u for u in os.listdir(corpus)
                                   if os.path.exists(os.path.join(corpus, u, 'system.xml.bz2')))
    print('| unit | atoms | constraints | SETTLE | SHAKE 1/2/3 | CCMA | fused path | leftover clusters |')
    print('|---|---:|---:|---:|---|---:|---|---|')
    for u in units:
        r = classify(load(os.path.join(corpus, u, 'system.xml.bz2')))
        shake = '/'.join(str(r['shake'][k]) for k in (1, 2, 3))
        kinds = Counter()
        for size, bonds in r['components']:
            kinds[(size, tuple(sorted(bonds.items())))] += 1
        left = '; '.join('%d x %d-constraint cluster (%s)' % (k, size, ', '.join('%s x%d' % b for b in bonds))
                         for (size, bonds), k in sorted(kinds.items(), key=lambda kv: -kv[1])) or 'none'
        fused = 'yes' if r['ccma'] == 0 else 'no'
        note = ' (%d SETTLE-shaped triangles rejected)' % r['settle_rejected'] if r['settle_rejected'] else ''
        print('| %s | %d | %d | %d | %s | %d | %s | %s%s |' % (
            u, r['atoms'], r['constraints'], r['settle'], shake, r['ccma'], fused, left, note))


if __name__ == '__main__':
    main()

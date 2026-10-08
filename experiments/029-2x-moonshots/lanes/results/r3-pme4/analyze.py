"""CPU-only PME mesh error sweep using OpenMM's unmodified ReferencePME.

All units are nm, e, kJ/mol. This evaluates only the mesh term. Direct,
self, and exclusion terms are identical between candidates and cancel.
Run with the r2/pmefft Python environment and the compiled bridge beside
this file, or set PME_BRIDGE to the bridge's absolute path.
"""
import argparse
import ast
import ctypes as C
from datetime import datetime, timezone
import gc
import json
import math
import os
from pathlib import Path
import sys
import time
import types

import numpy as np

ROOT = Path(__file__).resolve().parent
BENCH = Path('/tmp/openmm-metal-bench/ultra-base/benchmarks')
GRIDS = {'pme': (56,)*3, 'amber20-dhfr': (56,)*3,
         'apoa1pme': (98,)*3, 'apoa1ljpme': (98,)*3,
         'amber20-cellulose': (231, 112, 110),
         'amber20-stmv': (198, 200, 200)}
ALPHA = math.sqrt(-math.log(0.001))/0.9


def day_only():
    if datetime.now(timezone.utc).hour < 7:
        raise RuntimeError('Night timing slot: CPU analysis is prohibited')


def legal(n):
    while True:
        q = n
        for p in (2, 3, 5, 7, 11, 13):
            while q % p == 0:
                q //= p
        if q == 1:
            return n
        n += 1


def mesh(base, scale):
    return tuple(legal(math.ceil(n*scale-1e-9)) for n in base)


def legal_scales(base, low, high):
    """Every distinct legal mesh on the uniformly scaled path in this interval."""
    scales = {low, high}
    for n in base:
        for size in range(math.floor(n*low), math.ceil(n*high)):
            if legal(size) == size and low <= size/n < high:
                scales.add(size/n+1e-8)
    return sorted(scales)


class Reference:
    def __init__(self):
        self.lib = C.CDLL(os.environ.get('PME_BRIDGE', str(ROOT/'reference_bridge.dylib')))
        array = np.ctypeslib.ndpointer(dtype=np.float64, flags='C_CONTIGUOUS')
        grid = np.ctypeslib.ndpointer(dtype=np.int32, flags='C_CONTIGUOUS')
        self.lib.evaluate_pme.argtypes = [C.c_int, C.c_int, grid, C.c_double,
                                         array, array, array, C.c_int, array,
                                         C.POINTER(C.c_double)]
        self.lib.evaluate_pme.restype = C.c_int
        self.lib.pme_error.restype = C.c_char_p

    def __call__(self, xyz, charge, box, order, grid, dispersion=False, alpha=ALPHA):
        day_only()
        xyz, charge, box = [np.ascontiguousarray(x, dtype=np.float64)
                            for x in (xyz, charge, box)]
        forces = np.zeros_like(xyz)
        energy = C.c_double()
        status = self.lib.evaluate_pme(len(xyz), order, np.array(grid, dtype=np.int32),
                    alpha, xyz, charge, box, dispersion, forces, C.byref(energy))
        if status:
            raise RuntimeError(self.lib.pme_error().decode())
        return forces, energy.value


def prepare(name, steps):
    """Native benchmark topology, plus two short CPU MD configurations."""
    day_only()
    import openmm as mm
    from openmm import unit as u
    sys.path.insert(0, str(BENCH))
    # benchmark.py parses arguments and runs at import time. Load only its
    # imports and function definitions, so no GPU benchmark can start here.
    source = ast.parse((BENCH/'benchmark.py').read_text())
    source.body = [node for node in source.body
                   if isinstance(node, (ast.Import, ast.ImportFrom, ast.FunctionDef))]
    benchmark = types.ModuleType('benchmark_definitions')
    exec(compile(source, str(BENCH/'benchmark.py'), 'exec'), benchmark.__dict__)
    os.chdir(BENCH)
    system, positions, _ = benchmark.retrieveTestSystem(name)
    force = next(f for f in system.getForces() if isinstance(f, mm.NonbondedForce))
    assert force.getEwaldErrorTolerance() == 5e-4
    params = [force.getParticleParameters(i) for i in range(system.getNumParticles())]
    charge = np.array([p[0].value_in_unit(u.elementary_charge) for p in params])
    c6 = np.array([2*math.sqrt(p[2].value_in_unit(u.kilojoule_per_mole))*
                   p[1].value_in_unit(u.nanometer)**3 for p in params])
    box = np.asarray([v.value_in_unit(u.nanometer) for v in system.getDefaultPeriodicBoxVectors()])
    xyz = np.asarray(positions.value_in_unit(u.nanometer))
    snapshots = [xyz]
    if steps:
        integ = mm.LangevinMiddleIntegrator(300*u.kelvin, 1/u.picosecond, 0.002*u.picosecond)
        integ.setConstraintTolerance(1e-8)
        integ.setRandomNumberSeed(20260927)
        context = mm.Context(system, integ, mm.Platform.getPlatformByName('CPU'), {'Threads': '4'})
        context.setPositions(positions)
        context.setVelocitiesToTemperature(300*u.kelvin, 20260927)
        for _ in range(2):
            day_only()
            integ.step(steps)
            snapshots.append(context.getState(positions=True).getPositions(asNumpy=True).value_in_unit(u.nanometer))
        del context, integ
    np.savez(ROOT/f'{name}-input.npz', xyz=np.array(snapshots), charge=charge,
             c6=c6, box=box, steps=steps)
    print(json.dumps({'prepared': name, 'atoms': len(charge), 'frames': len(snapshots),
                      'steps_between_frames': steps}), flush=True)


def errors(forces, energy, ref, eref):
    delta = forces-ref
    norms = np.linalg.norm(ref, axis=1)
    dn = np.linalg.norm(delta, axis=1)
    return {'rms_relative': float(np.linalg.norm(delta)/np.linalg.norm(ref)),
            'max_relative': float(np.max(dn)/np.max(norms)),
            'max_atom_relative': float(np.max(dn/np.maximum(norms, 1e-30))),
            'rms_absolute': float(np.sqrt(np.mean(dn**2))),
            'max_absolute': float(np.max(dn)),
            'energy_error': energy-eref, 'energy_relative': abs((energy-eref)/eref)}


def sweep(name, orders, scales, frames, dense=None):
    data = np.load(ROOT/f'{name}-input.npz')
    engine = Reference()
    out = ROOT/f'{name}-sweep.jsonl'
    existing = [json.loads(line) for line in out.read_text().splitlines()] if out.exists() else []
    done = {(r['frame'], r['channel'], r['order'], tuple(r['grid'])) for r in existing}
    channels = [('coulomb', data['charge'], GRIDS[name], False)]
    if name == 'apoa1ljpme':
        channels.append(('dispersion', data['c6'], (49,)*3, True))
    for frame, xyz in enumerate(data['xyz'][:frames]):
        for channel, charge, base, dispersion in channels:
            # High order and twice the grid density, with independent convergence check.
            fine = mesh(base, 2)
            key = ROOT/f'{name}-{channel}-{frame}-reference.npz'
            if key.exists():
                cached = np.load(key)
                ref, eref = cached['forces'], float(cached['energy'])
            else:
                ref, eref = engine(xyz, charge, data['box'], 8, fine, dispersion)
                f2, e2 = engine(xyz, charge, data['box'], 7, fine, dispersion)
                print(json.dumps({'reference_convergence': name, 'frame': frame,
                      'channel': channel, 'grid': fine, **errors(f2, e2, ref, eref)}), flush=True)
                np.savez(key, forces=ref, energy=eref)
                del f2
            for order in orders:
                seen = set()
                candidates = legal_scales(base, *dense) if dense else scales
                for scale in ([1.] if order == 5 and orders != [5] else candidates):
                    grid = mesh(base, scale)
                    if grid in seen or (frame, channel, order, grid) in done:
                        continue
                    seen.add(grid)
                    start = time.monotonic()
                    f, e = engine(xyz, charge, data['box'], order, grid, dispersion)
                    row = {'test': name, 'frame': frame, 'channel': channel,
                           'order': order, 'grid': grid, 'scale': scale,
                           'reference_order': 8, 'reference_grid': fine,
                           'atoms': len(xyz), 'seconds': time.monotonic()-start,
                           **errors(f, e, ref, eref)}
                    with out.open('a') as stream:
                        stream.write(json.dumps(row)+'\n')
                    print(json.dumps(row), flush=True)
                    del f
            del ref
            gc.collect()


def validate():
    """Independent direct reciprocal Ewald sum, plus finite difference force."""
    engine = Reference()
    rng = np.random.default_rng(20260927)
    xyz = rng.random((32, 3))*3
    q = rng.normal(size=32)
    q -= q.mean()
    box = np.eye(3)*3
    k = np.stack(np.meshgrid(*([np.arange(-14, 15)]*3), indexing='ij'), -1).reshape(-1, 3)
    k = k[np.any(k != 0, axis=1)]/3
    k2 = np.sum(k*k, axis=1)
    factor = 138.93545764438198/(math.pi*27)*np.exp(-math.pi**2*k2/ALPHA**2)/k2
    phase = np.exp(2j*math.pi*xyz@k.T)
    rho = q@phase
    energy = 0.5*np.sum(factor*abs(rho)**2)
    force = (q[:, None]*(phase*rho.conj()*factor).imag)@(2*math.pi*k)
    rows = []
    for order, grid in [(4, (64,)*3), (5, (64,)*3), (8, (96,)*3)]:
        f, e = engine(xyz, q, box, order, grid)
        row = {'order': order, 'grid': grid, **errors(f, e, force, energy)}
        h = 1e-5
        xp, xm = xyz.copy(), xyz.copy()
        xp[0, 0] += h
        xm[0, 0] -= h
        numerical = -(engine(xp, q, box, order, grid)[1]-engine(xm, q, box, order, grid)[1])/(2*h)
        row['finite_difference_error'] = float(numerical-f[0, 0])
        assert abs(numerical-f[0, 0]) < 1e-5
        assert row['rms_relative'] < (1e-8 if order == 8 else 1e-3)
        rows.append(row)
    (ROOT/'validation.json').write_text(json.dumps(rows, indent=2)+'\n')
    print(json.dumps(rows), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['prepare', 'sweep', 'validate'])
    parser.add_argument('--tests', nargs='+', default=list(GRIDS))
    parser.add_argument('--steps', type=int, default=100)
    parser.add_argument('--orders', nargs='+', type=int, default=[5, 4])
    parser.add_argument('--scales', nargs='+', type=float, default=[1.25, 1.375, 1.5, 1.625, 1.75])
    parser.add_argument('--frames', type=int, default=3)
    parser.add_argument('--dense', nargs=2, type=float, metavar=('MIN', 'MAX'))
    args = parser.parse_args()
    if args.action == 'validate':
        validate()
    else:
        for name in args.tests:
            if args.action == 'prepare':
                prepare(name, args.steps)
            else:
                sweep(name, args.orders, args.scales, args.frames, args.dense)

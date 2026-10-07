"""Run a Folding@home-style work unit on Metal and check it against Reference at FAH's default tolerances.

    python wu.py run <wu dir> <out dir> <precision> <steps> <checks>   (GPU, inside a correctness lease)
    python wu.py compare <out dir> ...                                  (CPU only, Reference)

A work unit is a directory holding system.xml[.bz2], state.xml[.bz2] and integrator.xml[.bz2], the objects an
FAH OpenMM core loads.  `run` loads them the way a core does (deserialize, Context, setState), integrates in
<checks> equal chunks, and saves positions, box, context parameters, forces and energy after each chunk (and at
step 0).  `compare` evaluates the same configurations on Reference and reports the worst per-atom force
difference, the energy difference and the worst relative constraint error.  FAH's public defaults
(alchemiscale-fah settings) are 5 kJ/mol/nm for forces and 10 kJ/mol for energy.
"""
import bz2
import glob
import json
import math
import os
import sys
import time

import numpy as np
import openmm as mm

FORCE_TOL = 5.0
ENERGY_TOL = 10.0


def load(wu, name):
    for path, opener in ((os.path.join(wu, name + '.xml.bz2'), bz2.open), (os.path.join(wu, name + '.xml'), open)):
        if os.path.exists(path):
            with opener(path, 'rt') as f:
                return mm.XmlSerializer.deserialize(f.read())
    raise FileNotFoundError(os.path.join(wu, name + '.xml'))


def integrator_globals(integrator):
    if not isinstance(integrator, mm.CustomIntegrator):
        return {}
    return {integrator.getGlobalVariableName(i): integrator.getGlobalVariable(i)
            for i in range(integrator.getNumGlobalVariables())}


def snapshot(context, integrator, step, path):
    state = context.getState(getPositions=True, getForces=True, getEnergy=True, getParameters=True)
    np.savez(path,
             positions=state.getPositions(asNumpy=True)._value,
             box=state.getPeriodicBoxVectors(asNumpy=True)._value,
             forces=state.getForces(asNumpy=True)._value,
             energy=state.getPotentialEnergy()._value,
             step=step,
             parameters=json.dumps(dict(state.getParameters())),
             globals=json.dumps(integrator_globals(integrator)))


def run(wu, out, precision, steps, checks):
    os.makedirs(out, exist_ok=True)
    system, integrator, state = load(wu, 'system'), load(wu, 'integrator'), load(wu, 'state')
    platform = mm.Platform.getPlatformByName('Metal')
    start = time.time()
    context = mm.Context(system, integrator, platform, {'Precision': precision})
    context.setState(state)
    snapshot(context, integrator, 0, os.path.join(out, 'check-0.npz'))
    setup = time.time() - start
    chunk = steps//checks
    error = None
    start = time.time()
    for k in range(1, checks + 1):
        try:
            integrator.step(chunk)
        except Exception as e:
            error = '%s at chunk %d' % (e, k)
            break
        snapshot(context, integrator, k*chunk, os.path.join(out, 'check-%d.npz' % k))
    meta = dict(wu=os.path.abspath(wu), precision=precision, steps=steps, checks=checks, setup_s=setup,
                run_s=time.time() - start, error=error, atoms=system.getNumParticles(),
                device=platform.getPropertyValue(context, 'DeviceName') if 'DeviceName' in platform.getPropertyNames() else '')
    with open(os.path.join(out, 'run.json'), 'w') as f:
        json.dump(meta, f, indent=1)
    print(json.dumps(meta), flush=True)


def constraint_error(system, positions, box):
    if system.getNumConstraints() == 0:
        return 0.0
    params = [system.getConstraintParameters(i) for i in range(system.getNumConstraints())]
    p1 = np.array([p[0] for p in params])
    p2 = np.array([p[1] for p in params])
    d = np.array([p[2]._value for p in params])
    delta = positions[p1] - positions[p2]
    if system.usesPeriodicBoundaryConditions():
        delta -= np.round(delta @ np.linalg.inv(box)) @ box
    return float(np.max(np.abs(np.linalg.norm(delta, axis=1) - d)/d))


def compare(out):
    meta = json.load(open(os.path.join(out, 'run.json')))
    system = load(meta['wu'], 'system')
    reference = mm.Context(system, mm.VerletIntegrator(0.001), mm.Platform.getPlatformByName('Reference'))
    rows = []
    for path in sorted(glob.glob(os.path.join(out, 'check-*.npz')), key=lambda p: int(p.split('-')[-1][:-4])):
        snap = np.load(path)
        for name, value in json.loads(str(snap['parameters'])).items():
            reference.setParameter(name, value)
        box = snap['box']
        reference.setPeriodicBoxVectors(*[mm.Vec3(*row) for row in box])
        reference.setPositions(snap['positions'])
        ref = reference.getState(getForces=True, getEnergy=True)
        ref_forces = ref.getForces(asNumpy=True)._value
        diff = np.linalg.norm(snap['forces'] - ref_forces, axis=1)
        finite = bool(np.all(np.isfinite(snap['forces'])) and math.isfinite(float(snap['energy'])))
        row = dict(step=int(snap['step']), max_df=float(diff.max()), rms_df=float(np.sqrt((diff**2).mean())),
                   atoms_over=int((diff > FORCE_TOL).sum()), metal_e=float(snap['energy']),
                   de=float(snap['energy']) - ref.getPotentialEnergy()._value,
                   constraint=constraint_error(system, snap['positions'], box), finite=finite,
                   globals=json.loads(str(snap['globals'])))
        row['pass'] = finite and row['max_df'] <= FORCE_TOL and abs(row['de']) <= ENERGY_TOL
        rows.append(row)
    ok = meta['error'] is None and len(rows) == meta['checks'] + 1 and all(r['pass'] for r in rows)
    summary = dict(case=os.path.basename(meta['wu']), precision=meta['precision'], atoms=meta['atoms'],
                   steps=meta['steps'], error=meta['error'], checks=len(rows),
                   max_df=max(r['max_df'] for r in rows), max_abs_de=max(abs(r['de']) for r in rows),
                   max_constraint=max(r['constraint'] for r in rows), verdict='PASS' if ok else 'FAIL', rows=rows)
    with open(os.path.join(out, 'compare.json'), 'w') as f:
        json.dump(summary, f, indent=1)
    print('%-10s %-6s atoms %6d steps %5d checks %d max|dF| %.4f max|dE| %.3f constraint %.1e %s%s' % (
        summary['case'], summary['precision'], summary['atoms'], summary['steps'], summary['checks'],
        summary['max_df'], summary['max_abs_de'], summary['max_constraint'], summary['verdict'],
        '' if meta['error'] is None else ' (' + meta['error'] + ')'), flush=True)


if __name__ == '__main__':
    if sys.argv[1] == 'run':
        run(sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5]), int(sys.argv[6]))
    else:
        for out in sys.argv[2:]:
            compare(out)

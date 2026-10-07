"""Restart and failure behaviour of a Folding@home-style work unit on Metal.

    python restart.py <wu dir> <precision> [deterministic] [nobarostat]   (GPU, inside a correctness lease)

Checks, each printed as one PASS/FAIL line:
  binary     Run, createCheckpoint() mid-protocol, run on.  Load the checkpoint into a fresh Context and integrator:
             CustomIntegrator globals and per-DOF variables must come back bit for bit, and the continuation must
             match the original run (bit for bit with DeterministicForces=true, otherwise report the divergence).
  xml        The FAH path: serialize State (positions, velocities, parameters, integrator parameters) and the
             integrator mid-run, rebuild a fresh Context from the XML only, and require the same globals and per-DOF
             variables bit for bit, positions and velocities within 1e-6, then continue and require finite energies.
             XML carries no random-number state, so the continuation is a new stochastic trajectory.
  nan        Put a NaN coordinate into a running Context.  The next step or getState must raise or report a
             non-finite energy, never the previous finite one.
  rollback   After the NaN, load the last good checkpoint into the same Context and continue: energies must be
             finite and match the checkpoint's energy.
"""
import bz2
import math
import os
import sys

import numpy as np
import openmm as mm

N1, N2 = 300, 200


def load(wu, name):
    with bz2.open(os.path.join(wu, name + '.xml.bz2'), 'rt') as f:
        return mm.XmlSerializer.deserialize(f.read())


def custom_state(integrator):
    if not isinstance(integrator, mm.CustomIntegrator):
        return {}, {}
    g = {integrator.getGlobalVariableName(i): integrator.getGlobalVariable(i) for i in range(integrator.getNumGlobalVariables())}
    p = {integrator.getPerDofVariableName(i): np.array(integrator.getPerDofVariable(i)) for i in range(integrator.getNumPerDofVariables())}
    return g, p


def same(a, b):
    return all(np.array_equal(a[k], b[k]) for k in a) and a.keys() == b.keys()


def snapshot(context):
    s = context.getState(getPositions=True, getVelocities=True, getEnergy=True)
    return s.getPositions(asNumpy=True)._value, s.getVelocities(asNumpy=True)._value, s.getPotentialEnergy()._value


def report(name, ok, detail):
    print('%-8s %s %s' % (name, 'PASS' if ok else 'FAIL', detail), flush=True)
    return ok


def main(wu, precision, deterministic, nobarostat):
    system = load(wu, 'system')
    if nobarostat:
        for i in reversed(range(system.getNumForces())):
            if isinstance(system.getForce(i), mm.MonteCarloBarostat):
                system.removeForce(i)
    wu_integrator_xml = mm.XmlSerializer.serialize(load(wu, 'integrator'))
    wu_state = load(wu, 'state')
    platform = mm.Platform.getPlatformByName('Metal')
    props = {'Precision': precision, 'DeterministicForces': 'true' if deterministic else 'false'}

    def fresh(integrator_xml):
        integrator = mm.XmlSerializer.deserialize(integrator_xml)
        integrator.setRandomNumberSeed(2026)
        return integrator, mm.Context(system, integrator, platform, props)

    integrator, context = fresh(wu_integrator_xml)
    context.setPeriodicBoxVectors(*wu_state.getPeriodicBoxVectors())
    context.setPositions(wu_state.getPositions())
    context.setVelocities(wu_state.getVelocities())
    for name, value in wu_state.getParameters().items():
        if name in context.getParameters():
            context.setParameter(name, value)
    integrator.step(N1)
    checkpoint = context.createCheckpoint()
    state_xml = mm.XmlSerializer.serialize(context.getState(getPositions=True, getVelocities=True, getParameters=True,
                                                            getIntegratorParameters=True))
    integrator_xml = mm.XmlSerializer.serialize(integrator)
    g1, p1 = custom_state(integrator)
    x1, v1, e1 = snapshot(context)
    integrator.step(N2)
    g2, _ = custom_state(integrator)
    x2, v2, e2 = snapshot(context)
    work = 'protocol_work' in g1
    results = []

    # Binary checkpoint into a fresh Context.
    integrator_b, context_b = fresh(wu_integrator_xml)
    context_b.loadCheckpoint(checkpoint)
    gb, pb = custom_state(integrator_b)
    xb, vb, eb = snapshot(context_b)
    restored = same(g1, gb) and same(p1, pb) and np.array_equal(x1, xb) and np.array_equal(v1, vb)
    integrator_b.step(N2)
    gb2, _ = custom_state(integrator_b)
    xb2, _, eb2 = snapshot(context_b)
    dx = float(np.abs(xb2 - x2).max())
    dwork = abs(gb2['protocol_work'] - g2['protocol_work']) if work else 0.0
    continued = (dx == 0 and dwork == 0) if deterministic else math.isfinite(eb2)
    results.append(report('binary', restored and continued,
                          'restored %s, after %d more steps max|dx| %.3g nm, dE %.3g, d(work) %.3g%s' % (
                              restored, N2, dx, eb2 - e2, dwork,
                              ', work %.4f' % g2['protocol_work'] if work else '')))

    # XML state plus serialized integrator into a fresh Context, the way an FAH core restarts.
    integrator_c, context_c = fresh(integrator_xml)
    context_c.setState(mm.XmlSerializer.deserialize(state_xml))
    gc, pc = custom_state(integrator_c)
    xc, vc, ec = snapshot(context_c)
    # setState() may move a position by one float ulp when it images molecules, and mixed velocities may be
    # stored as float pairs, so positions and velocities get a tolerance.  Globals and per-DOF values must be exact.
    dxc, dvc = float(np.abs(x1 - xc).max()), float(np.abs(v1 - vc).max())
    restored = same(g1, gc) and same(p1, pc) and dxc <= 1e-6 and dvc <= 1e-6
    missing = [k for k in g1 if g1[k] != gc.get(k)] + [k for k in p1 if not np.array_equal(p1[k], pc.get(k))]
    integrator_c.step(N2)
    gc2, _ = custom_state(integrator_c)
    _, _, ec2 = snapshot(context_c)
    results.append(report('xml', restored and math.isfinite(ec2),
                          'restored %s%s, max|dx| %.2g nm, max|dv| %.2g nm/ps, dE at restart %.3g, after %d steps E %.1f (original %.1f)%s' % (
                              restored, (' differs: ' + ','.join(missing)) if missing else '', dxc, dvc, ec - e1, N2, ec2, e2,
                              ', work %.4f (original %.4f)' % (gc2['protocol_work'], g2['protocol_work']) if work else '')))

    # NaN coordinate in the running Context.
    bad = x2.copy()
    bad[len(bad)//2] = np.nan
    context.setPositions(bad)
    raised, energy = None, None
    try:
        integrator.step(10)
        energy = context.getState(getEnergy=True).getPotentialEnergy()._value
    except Exception as e:
        raised = str(e).split('.')[0]
    ok = raised is not None or not math.isfinite(energy)
    results.append(report('nan', ok, 'raised: %s' % raised if raised else 'energy after 10 steps: %s' % energy))

    # Roll back to the last good checkpoint in the same Context.
    try:
        context.loadCheckpoint(checkpoint)
        _, _, er = snapshot(context)
        integrator.step(N2)
        _, _, er2 = snapshot(context)
        ok = abs(er - e1) <= max(0.1, 1e-6*abs(e1)) and math.isfinite(er2)
        results.append(report('rollback', ok, 'energy at checkpoint %.4f (saved %.4f), after %d steps %.1f' % (er, e1, N2, er2)))
    except Exception as e:
        results.append(report('rollback', False, 'raised: %s' % e))
    return all(results)


if __name__ == '__main__':
    wu, precision = sys.argv[1], sys.argv[2]
    deterministic = 'deterministic' in sys.argv[3:]
    nobarostat = 'nobarostat' in sys.argv[3:]
    print('== %s %s%s' % (os.path.basename(wu.rstrip('/')), precision, ''.join(' ' + a for a in sys.argv[3:])), flush=True)
    sys.exit(0 if main(wu, precision, deterministic, nobarostat) else 1)

"""Is the md100 max|dF| outlier a pair sitting on the cutoff? (diag6: rf single, MAX_BITS 0, atom 14426, 1.5.)

Runs forces.py's 100 LangevinMiddle steps in Metal single with the knobs from argv, then at the reached
positions finds the atom with the largest Metal vs Reference force difference, and lists its non-excluded
partners whose minimum-image distance is within 1e-4 nm of the cutoff, with each pair's force at that distance.
If Metal (float r2) and Reference (double r2) put one of those pairs on opposite sides of the cutoff, the
difference equals that pair's force: same magnitude, cosine +-1, and the partner carries the opposite error.
usage: python mdstraddle.py <benchmarks dir> <tests> [NAME=value ...]
"""
import os
import sys

import numpy as np
import openmm as mm
import openmm.unit as u

SEED = 2026
STEPS = 100
BAND = 1e-4
ONE_4PI_EPS0 = 138.935456
bench, tests = sys.argv[1], sys.argv[2].split(",")
os.environ.update(dict(arg.split("=", 1) for arg in sys.argv[3:]))
os.chdir(bench)
source = open("benchmark.py").read()
exec(source[:source.index("def serializeTest")])


def forces(context):
    state = context.getState(getForces=True)
    return np.array(state.getForces(asNumpy=True).value_in_unit(u.kilojoule_per_mole/u.nanometer))


def pair_force(nb, i, j, delta, krf):
    qi, si, ei = nb.getParticleParameters(i)
    qj, sj, ej = nb.getParticleParameters(j)
    qq = (qi*qj).value_in_unit(u.elementary_charge**2)
    sig = 0.5*(si+sj).value_in_unit(u.nanometer)
    eps = np.sqrt((ei*ej).value_in_unit(u.kilojoule_per_mole**2))
    r = np.linalg.norm(delta)
    coulomb = ONE_4PI_EPS0*qq*(1/r**2 - 2*krf*r) if krf is not None else 0.0
    lj = 4*eps*(12*sig**12/r**13 - 6*sig**6/r**7)
    return -(coulomb+lj)*delta/r


for test in tests:
    system, positions, _ = retrieveTestSystem(test)
    nb = next(f for f in system.getForces() if isinstance(f, mm.NonbondedForce))
    rc = nb.getCutoffDistance().value_in_unit(u.nanometer)
    krf = None
    if nb.getNonbondedMethod() in (mm.NonbondedForce.CutoffPeriodic, mm.NonbondedForce.CutoffNonPeriodic):
        e = nb.getReactionFieldDielectric()
        krf = (e-1)/(2*e+1)/rc**3
    integrator = mm.LangevinMiddleIntegrator(300*u.kelvin, 1/u.picosecond, 0.004*u.picoseconds)
    integrator.setRandomNumberSeed(SEED)
    context = mm.Context(system, integrator, mm.Platform.getPlatformByName("Metal"), {"Precision": "single"})
    context.setPositions(positions)
    context.setVelocitiesToTemperature(300*u.kelvin, SEED)
    integrator.step(STEPS)
    state = context.getState(getPositions=True, getForces=True)
    fmetal = np.array(state.getForces(asNumpy=True).value_in_unit(u.kilojoule_per_mole/u.nanometer))
    reached = state.getPositions(asNumpy=True)
    ref = mm.Context(system, mm.VerletIntegrator(0.001), mm.Platform.getPlatformByName("Reference"))
    ref.setPositions(reached)
    fref = forces(ref)
    diff = fmetal-fref
    order = np.argsort(-np.linalg.norm(diff, axis=1))
    pos = reached.value_in_unit(u.nanometer)
    box = np.array([v.value_in_unit(u.nanometer) for v in state.getPeriodicBoxVectors()]).diagonal()
    excluded = {}
    for k in range(nb.getNumExceptions()):
        a, b, *_ = nb.getExceptionParameters(k)
        excluded.setdefault(a, set()).add(b)
        excluded.setdefault(b, set()).add(a)
    print(f"== {test} cutoff {rc} krf {krf} knobs {sys.argv[3:] or 'default'}", flush=True)
    for i in order[:3]:
        print(f"  atom {i}: |dF| {np.linalg.norm(diff[i]):.3e} dF {np.round(diff[i], 4)}")
        delta = pos-pos[i]
        delta -= box*np.round(delta/box)
        r = np.linalg.norm(delta, axis=1)
        for j in np.flatnonzero(np.abs(r-rc) < BAND):
            if j == i or j in excluded.get(i, ()):
                continue
            f = pair_force(nb, i, j, -delta[j], krf)
            cos = f @ diff[i]/(np.linalg.norm(f)*np.linalg.norm(diff[i]))
            print(f"    partner {j}: r-rc {r[j]-rc:+.3e} |F(pair)| {np.linalg.norm(f):.3e} cos {cos:+.3f}"
                  f" partner |dF| {np.linalg.norm(diff[j]):.3e} cos(dF_i, dF_j) "
                  f"{diff[i] @ diff[j]/(np.linalg.norm(diff[i])*np.linalg.norm(diff[j])):+.3f}")
    sys.stdout.flush()

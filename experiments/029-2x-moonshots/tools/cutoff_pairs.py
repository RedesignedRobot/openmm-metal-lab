"""Reconcile proven cutoff jumps (reaction field, PME, LJPME), preserving all other force error."""
from math import erfc, exp, log, pi, sqrt

import numpy as np
import openmm as mm
import openmm.unit as u

STRADDLE_ULPS = 4
STRADDLE_CANDIDATES = 64
ONE_4PI_EPS0 = 138.935456
CUTOFF = (mm.NonbondedForce.CutoffPeriodic, mm.NonbondedForce.CutoffNonPeriodic)
EWALD = (mm.NonbondedForce.PME, mm.NonbondedForce.LJPME)


def ewald_alpha(nb, lj):
    # NonbondedForceImpl::calcPMEParameters: an explicit alpha wins, else sqrt(-log(2 tol))/cutoff.
    alpha = (nb.getLJPMEParameters() if lj else nb.getPMEParameters())[0]
    alpha = alpha.value_in_unit(u.nanometer**-1) if u.is_quantity(alpha) else float(alpha)
    if alpha == 0:
        alpha = sqrt(-log(2*nb.getEwaldErrorTolerance()))/nb.getCutoffDistance().value_in_unit(u.nanometer)
    return alpha


def pair_amplitude(nb, i, j, r, cutoff):
    """-dE/dr of the direct-space pair at r, as ReferenceLJCoulombIxn computes it."""
    qi, si, ei = nb.getParticleParameters(i)
    qj, sj, ej = nb.getParticleParameters(j)
    qq = (qi*qj).value_in_unit(u.elementary_charge**2)
    si, sj = si.value_in_unit(u.nanometer), sj.value_in_unit(u.nanometer)
    ei, ej = ei.value_in_unit(u.kilojoule_per_mole), ej.value_in_unit(u.kilojoule_per_mole)
    method = nb.getNonbondedMethod()
    sigma = 0.5*(si+sj)
    epsilon = sqrt(ei*ej)
    sr6 = (sigma/r)**6
    lj = 24*epsilon*(2*sr6**2-sr6)/r
    if nb.getUseSwitchingFunction():
        switch = nb.getSwitchingDistance().value_in_unit(u.nanometer)
        if r > switch:
            x = (r-switch)/(cutoff-switch)
            scale_lj = 1+x**3*(-10+x*(15-6*x))
            derivative = -30*x*x*(1-x)**2/(cutoff-switch)
            lj = scale_lj*lj-4*epsilon*(sr6**2-sr6)*derivative
    if method in CUTOFF:
        dielectric = nb.getReactionFieldDielectric()
        krf = (dielectric-1)/(2*dielectric+1)/cutoff**3
        return ONE_4PI_EPS0*qq*(1/r**2-2*krf*r)+lj
    alpha_r = ewald_alpha(nb, False)*r
    coulomb = ONE_4PI_EPS0*qq*(erfc(alpha_r)+2*alpha_r*exp(-alpha_r**2)/sqrt(pi))/r**2
    if method == mm.NonbondedForce.LJPME:
        # Geometric C6 dispersion screened by the dispersion Ewald alpha (ReferenceLJCoulombIxn.cpp).
        c6 = 4*(si*sj)**3*epsilon
        a2 = (ewald_alpha(nb, True)*r)**2
        lj += 6*c6/r**7*(1-exp(-a2)*(1+a2+a2**2/2+a2**3/6))
    return coulomb+lj


def reconcile(system, positions, error):
    forces = [f for f in system.getForces() if isinstance(f, mm.NonbondedForce)]
    if len(forces) != 1:
        return error.copy(), [], 0.0
    nb = forces[0]
    if nb.getNonbondedMethod() not in CUTOFF+EWALD:
        return error.copy(), [], 0.0
    if nb.getNumParticleParameterOffsets() or nb.getNumExceptionParameterOffsets():
        return error.copy(), [], 0.0
    periodic = nb.usesPeriodicBoundaryConditions()
    matrix = np.array([v.value_in_unit(u.nanometer) for v in system.getDefaultPeriodicBoxVectors()])
    if periodic and np.any(matrix != np.diag(np.diag(matrix))):
        return error.copy(), [], 0.0
    box = np.diag(matrix)
    cutoff = nb.getCutoffDistance().value_in_unit(u.nanometer)
    scale = box.max() if periodic else max(np.abs(positions).max(), cutoff)
    band = float(STRADDLE_ULPS*np.spacing(np.float32(scale)))
    # Exceptions have no cutoff under any method, so they never straddle.
    exclusions = {tuple(sorted(nb.getExceptionParameters(k)[:2])) for k in range(nb.getNumExceptions())}
    pairs = set()
    for i in np.argsort(-np.linalg.norm(error, axis=1))[:STRADDLE_CANDIDATES]:
        delta = positions-positions[i]
        if periodic:
            delta -= box*np.round(delta/box)
        distances = np.linalg.norm(delta, axis=1)
        for j in np.flatnonzero(np.abs(distances-cutoff) <= band):
            pair = tuple(sorted((int(i), int(j))))
            if i != j and pair not in exclusions:
                pairs.add(pair)
    corrected = error.copy()
    accepted = []
    for i, j in sorted(pairs):
        delta = positions[j]-positions[i]
        if periodic:
            delta -= box*np.round(delta/box)
        distance = np.linalg.norm(delta)
        # Evaluate the continuous inside-cutoff expression, not a force-error projection.
        amplitude = pair_amplitude(nb, i, j, min(distance, cutoff), cutoff)
        pair_force = -amplitude*delta/distance
        jump = (-1 if distance < cutoff else 1)*pair_force
        magnitude = np.linalg.norm(jump)
        if magnitude == 0:
            continue
        # Both atoms must independently exhibit this opposite pair jump. Never drop an atom.
        if (np.linalg.norm(corrected[i]-jump) > 0.1*magnitude or
                np.linalg.norm(corrected[j]+jump) > 0.1*magnitude):
            continue
        corrected[i] -= jump
        corrected[j] += jump
        accepted.append({'i': i, 'j': j, 'distance_minus_cutoff_nm': float(distance-cutoff),
                         'pair_force_norm': float(magnitude)})
    return corrected, accepted, band

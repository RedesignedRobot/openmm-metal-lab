"""Split the STMV direct-space energy error of float32 GPU evaluation into its sources, on the host.

usage: python stmv_direct_bias.py <amber20-suite-dir> <out.json>

Builds amber20-stmv as benchmark.py does (PME, 0.9 nm, HBonds) and evaluates every direct-space term three ways:
  ref   the Reference formulas in float64 (exact erf/erfc, double positions and charges)
  as64  float64 arithmetic, but the pair kernel's Abramowitz-Stegun erfc and the Metal erf Taylor series
  f32   the Metal single-precision kernels op by op in float32 (float positions, charges, constants), with
        correctly rounded exp/rsqrt/divide standing in for fast:: (the GPU's own approximations add to this)
Each term is rounded to float32 in f32 and summed in float64, so summation error is left out.
Components: pair (non-excluded pairs inside the cutoff, Coulomb and LJ), excl (the erf correction subtracted
for every exception) and exc (nonzero exceptions, plain Coulomb and LJ).
"""
import json
import sys
import time

import numpy as np
import openmm as mm
import openmm.app as app
import openmm.unit as u
from scipy.spatial import cKDTree
from scipy.special import erf, erfc

ONE_4PI_EPS0 = 138.935456
F = np.float32


def build(suite):
    prmtop = app.AmberPrmtopFile(f"{suite}/PME/Topologies/STMV.prmtop")
    inpcrd = app.AmberInpcrdFile(f"{suite}/PME/Coordinates/STMV.inpcrd")
    system = prmtop.createSystem(nonbondedMethod=app.PME, nonbondedCutoff=0.9 * u.nanometers, constraints=app.HBonds)
    nb = next(f for f in system.getForces() if isinstance(f, mm.NonbondedForce))
    n = nb.getNumParticles()
    q = np.empty(n); sig = np.empty(n); eps = np.empty(n)
    for i in range(n):
        c, s, e = nb.getParticleParameters(i)
        q[i] = c.value_in_unit(u.elementary_charge); sig[i] = s.value_in_unit(u.nanometer); eps[i] = e.value_in_unit(u.kilojoule_per_mole)
    m = nb.getNumExceptions()
    ea = np.empty((m, 2), dtype=np.int64); ep = np.empty((m, 3))
    for k in range(m):
        i, j, c, s, e = nb.getExceptionParameters(k)
        ea[k] = (min(i, j), max(i, j))
        ep[k] = (c.value_in_unit(u.elementary_charge**2), s.value_in_unit(u.nanometer), e.value_in_unit(u.kilojoule_per_mole))
    pos = inpcrd.getPositions(asNumpy=True).value_in_unit(u.nanometer)
    box = np.array([v[k] for k, v in enumerate(inpcrd.getBoxVectors().value_in_unit(u.nanometer))])
    cutoff = nb.getCutoffDistance().value_in_unit(u.nanometer)
    alpha = np.sqrt(-np.log(2 * nb.getEwaldErrorTolerance())) / cutoff
    return q, sig, eps, ea, ep, np.asarray(pos), box, cutoff, alpha


def erfc_as(x, dtype):
    """The pair kernel's single-precision erfc, evaluated in dtype."""
    one = dtype(1)
    t = one / (one + dtype(0.3275911) * x)
    poly = (dtype(0.254829592) + (dtype(-0.284496736) + (dtype(1.421413741) + (dtype(-1.453152027) + dtype(1.061405429) * t) * t) * t) * t) * t
    return poly * np.exp(-x * x).astype(dtype)


def erf_metal(x, dtype):
    """common.metal erf: Taylor series below 0.5, 1-erfc above."""
    x2 = x * x
    c = [dtype(v) for v in (1.1283791670955126, -1.0 / 3.0, 1.0 / 10.0, -1.0 / 42.0, 1.0 / 216.0, -1.0 / 1320.0)]
    series = c[0] * x * (dtype(1) + x2 * (c[1] + x2 * (c[2] + x2 * (c[3] + x2 * (c[4] + x2 * c[5])))))
    u_ = dtype(1) / (dtype(1) + dtype(0.47) * x)
    poly = ((((((dtype(0.0966678) * u_ - dtype(0.4607003)) * u_ + dtype(0.6896449)) * u_ - dtype(0.21611532)) * u_ + dtype(0.3931878)) * u_ + dtype(0.22740916)) * u_ + dtype(0.2701903)) * u_ - dtype(0.00028434425)
    tail = dtype(1) - poly * np.exp(-x * x).astype(dtype)
    return np.where(np.abs(x) >= dtype(0.5), tail, series)


def min_image(d, box, dtype):
    b = box.astype(dtype)
    inv = (dtype(1) / b).astype(dtype)
    return d - np.floor(d * inv + dtype(0.5)).astype(dtype) * b


def r2_of(d):
    return d[:, 0] * d[:, 0] + d[:, 1] * d[:, 1] + d[:, 2] * d[:, 2]


def pair_terms(i, j, pos, pos32, q, q32, sig, eps, se32, box, alpha):
    d = min_image(pos[j] - pos[i], box, np.float64)
    r = np.sqrt(r2_of(d))
    s = 0.5 * (sig[i] + sig[j]); e = np.sqrt(eps[i] * eps[j])
    sr6 = (s / r) ** 6
    lj = 4 * e * sr6 * (sr6 - 1)
    pref = ONE_4PI_EPS0 * q[i] * q[j] / r
    ref_c = pref * erfc(alpha * r)
    as_c = pref * erfc_as(alpha * r, np.float64)
    # float32, as coulombLennardJones.cc runs in single
    d32 = min_image(pos32[j] - pos32[i], box, F)
    r2 = r2_of(d32).astype(F)
    invR = (1 / np.sqrt(r2.astype(np.float64))).astype(F)
    r32 = (r2 * invR).astype(F)
    aR = (F(alpha) * r32).astype(F)
    ec = erfc_as(aR, F)
    p32 = (F(ONE_4PI_EPS0) * q32[i] * q32[j] * invR).astype(F)
    sg = (se32[i, 0] + se32[j, 0]).astype(F)
    sig2 = (invR * sg) ** 2
    sig6 = (sig2 * sig2 * sig2).astype(F)
    epssig6 = (sig6 * (se32[i, 1] * se32[j, 1])).astype(F)
    lj32 = (epssig6 * (sig6 - F(1))).astype(F)
    c32 = (p32 * ec).astype(F)
    return dict(pair_c_ref=ref_c.sum(), pair_c_as64=as_c.sum(), pair_c_f32=c32.astype(np.float64).sum(),
                pair_lj_ref=lj.sum(), pair_lj_f32=lj32.astype(np.float64).sum(), pairs=len(i))


def main():
    t0 = time.time()
    q, sig, eps, ea, ep, pos, box, cutoff, alpha = build(sys.argv[1])
    n = len(q)
    print(f"built n={n} exceptions={len(ea)} box={box} alpha={alpha:.10f} {time.time()-t0:.0f}s", flush=True)
    pos = pos - np.floor(pos / box) * box
    pos32 = pos.astype(F); q32 = q.astype(F)
    se32 = np.stack([0.5 * sig, 2 * np.sqrt(eps)], axis=1).astype(F)
    out = dict(n=n, alpha=alpha, box=box.tolist())

    # exclusion corrections, every exception
    i, j = ea[:, 0], ea[:, 1]
    d = min_image(pos[j] - pos[i], box, np.float64)
    r = np.sqrt(r2_of(d))
    P = ONE_4PI_EPS0 * q[i] * q[j]
    out["excl_ref"] = float(-(P * erf(alpha * r) / r).sum())
    out["excl_as64"] = float(-(P * erf_metal(alpha * r, np.float64) / r).sum())
    out["excl_lead_ref"] = float(-(P * alpha * 2 / np.sqrt(np.pi)).sum())
    d32 = min_image(pos32[j] - pos32[i], box, F)
    r32 = np.sqrt(r2_of(d32).astype(F)).astype(F)
    invR = (F(1) / r32).astype(F)
    aR = (F(alpha) * r32).astype(F)
    x32 = (F(ONE_4PI_EPS0) * (q32[i] * q32[j]).astype(F)).astype(F)
    e32 = -((x32 * invR).astype(F) * erf_metal(aR, F)).astype(F)
    out["excl_f32"] = float(e32.astype(np.float64).sum())
    # the same with the constant leading term taken out and added in double on the host
    lead = -(x32.astype(np.float64) * alpha * 2 / np.sqrt(np.pi))
    rest = -((x32 * invR).astype(F) * erf_metal(aR, F) - x32 * F(alpha * 2 / np.sqrt(np.pi))).astype(F)
    out["excl_f32_split"] = float(lead.sum() + rest.astype(np.float64).sum())
    # excl with the exact positions (only the float arithmetic differs)
    rr = r.astype(F)
    out["excl_f32_exactpos"] = float((-((x32 * (F(1) / rr)).astype(F) * erf_metal((F(alpha) * rr).astype(F), F)).astype(F)).astype(np.float64).sum())
    # float charges only, rest exact
    out["excl_q32_only"] = float(-(x32.astype(np.float64) * erf(alpha * r) / r).sum())
    print(f"excl done {time.time()-t0:.0f}s", flush=True)

    # nonzero exceptions
    nz = (ep[:, 0] != 0) | (ep[:, 2] != 0)
    i, j, c, s, e = ea[nz, 0], ea[nz, 1], ep[nz, 0], ep[nz, 1], ep[nz, 2]
    d = min_image(pos[j] - pos[i], box, np.float64)
    r = np.sqrt(r2_of(d))
    sr6 = (s / r) ** 6
    out["exc_ref"] = float((ONE_4PI_EPS0 * c / r + 4 * e * sr6 * (sr6 - 1)).sum())
    d32 = min_image(pos32[j] - pos32[i], box, F)
    invR = (1 / np.sqrt(r2_of(d32).astype(F).astype(np.float64))).astype(F)
    px, py, pz = F(ONE_4PI_EPS0) * c.astype(F), s.astype(F), (4 * e).astype(F)
    sig2 = ((invR * py) ** 2).astype(F)
    sig6 = (sig2 * sig2 * sig2).astype(F)
    t = ((pz * (sig6 - F(1))).astype(F) * sig6).astype(F) + (px * invR).astype(F)
    out["exc_f32"] = float(t.astype(np.float64).sum())
    print(f"exc done {time.time()-t0:.0f}s", flush=True)

    # pairs inside the cutoff, excluding every exception
    keys = np.sort(ea[:, 0] * n + ea[:, 1])
    tree = cKDTree(pos, boxsize=box)
    acc = {}
    chunk = 20000
    for a in range(0, n, chunk):
        sub = cKDTree(pos[a:a + chunk], boxsize=box)
        m = sub.sparse_distance_matrix(tree, cutoff, output_type="ndarray")
        i = m["i"].astype(np.int64) + a; j = m["j"].astype(np.int64)
        keep = j > i
        i, j = i[keep], j[keep]
        k = i * n + j
        idx = np.searchsorted(keys, k)
        idx[idx == len(keys)] = 0
        keep = keys[idx] != k
        i, j = i[keep], j[keep]
        # the GPU applies the cutoff to its own float r2, the host tree to the double r; the straddlers are noise
        for name, v in pair_terms(i, j, pos, pos32, q, q32, sig, eps, se32, box, alpha).items():
            acc[name] = acc.get(name, 0) + float(v)
        if a // chunk % 10 == 0:
            print(f"pairs {a}/{n} {time.time()-t0:.0f}s", flush=True)
    out.update(acc)
    out["direct_ref_no_dispersion"] = out["excl_ref"] + out["exc_ref"] + out["pair_c_ref"] + out["pair_lj_ref"]
    out["diff"] = {
        "excl f32-ref": out["excl_f32"] - out["excl_ref"],
        "excl as64-ref (Taylor erf)": out["excl_as64"] - out["excl_ref"],
        "excl q32only-ref": out["excl_q32_only"] - out["excl_ref"],
        "excl f32 exactpos-ref": out["excl_f32_exactpos"] - out["excl_ref"],
        "excl f32 split-ref": out["excl_f32_split"] - out["excl_ref"],
        "exc f32-ref": out["exc_f32"] - out["exc_ref"],
        "pair coulomb as64-ref (A&S erfc)": out["pair_c_as64"] - out["pair_c_ref"],
        "pair coulomb f32-ref": out["pair_c_f32"] - out["pair_c_ref"],
        "pair lj f32-ref": out["pair_lj_f32"] - out["pair_lj_ref"],
    }
    out["diff"]["total f32-ref"] = out["diff"]["excl f32-ref"] + out["diff"]["exc f32-ref"] + out["diff"]["pair coulomb f32-ref"] + out["diff"]["pair lj f32-ref"]
    out["wall_s"] = round(time.time() - t0)
    json.dump(out, open(sys.argv[2], "w"), indent=1)
    print(json.dumps(out["diff"], indent=1))


if __name__ == "__main__":
    main()

"""STMV pair-Coulomb error for candidate single-precision erfc approximations, float32 op by op against Reference.

usage: python stmv_erfc_variants.py <amber20-suite-dir> <fits.json>
fits.json maps a name to {"p": p, "c": [c0..cn]} for erfc(x) = t*(c0+c1*t+...+cn*t^n)*exp(-x*x), t = 1/(1+p*x).
"""
import json
import sys

import numpy as np
from scipy.spatial import cKDTree
from scipy.special import erfc

import stmv_direct_bias as s

F = np.float32
AS = dict(p=0.3275911, c=[0.254829592, -0.284496736, 1.421413741, -1.453152027, 1.061405429])


def erfc_fit(x, fit, dtype):
    t = dtype(1) / (dtype(1) + dtype(fit["p"]) * x)
    poly = dtype(fit["c"][-1])
    for c in fit["c"][-2::-1]:
        poly = dtype(c) + poly * t
    return t * poly * np.exp(-x * x).astype(dtype)


def main():
    fits = dict(AS=AS, **json.load(open(sys.argv[2])))
    q, sig, eps, ea, ep, pos, box, cutoff, alpha = s.build(sys.argv[1])
    n = len(q)
    pos = pos - np.floor(pos / box) * box
    pos32, q32 = pos.astype(F), q.astype(F)
    keys = np.sort(ea[:, 0] * n + ea[:, 1])
    tree = cKDTree(pos, boxsize=box)
    ref = 0.0
    acc = {name: [0.0, 0.0] for name in fits}
    for a in range(0, n, 20000):
        m = cKDTree(pos[a:a + 20000], boxsize=box).sparse_distance_matrix(tree, cutoff, output_type="ndarray")
        i = m["i"].astype(np.int64) + a; j = m["j"].astype(np.int64)
        keep = j > i
        i, j = i[keep], j[keep]
        k = i * n + j
        idx = np.searchsorted(keys, k); idx[idx == len(keys)] = 0
        keep = keys[idx] != k
        i, j = i[keep], j[keep]
        r = np.sqrt(s.r2_of(s.min_image(pos[j] - pos[i], box, np.float64)))
        pref = s.ONE_4PI_EPS0 * q[i] * q[j] / r
        ref += (pref * erfc(alpha * r)).sum()
        d32 = s.min_image(pos32[j] - pos32[i], box, F)
        r2 = s.r2_of(d32).astype(F)
        invR = (1 / np.sqrt(r2.astype(np.float64))).astype(F)
        aR = (F(alpha) * (r2 * invR).astype(F)).astype(F)
        p32 = (F(s.ONE_4PI_EPS0) * q32[i] * q32[j] * invR).astype(F)
        for name, fit in fits.items():
            acc[name][0] += (pref * erfc_fit(alpha * r, fit, np.float64)).sum()
            acc[name][1] += (p32 * erfc_fit(aR, fit, F)).astype(F).astype(np.float64).sum()
    for name, (e64, e32) in acc.items():
        print(f"{name}: approximation alone {e64 - ref:+.3f}  float32 {e32 - ref:+.3f} kJ/mol")


if __name__ == "__main__":
    main()

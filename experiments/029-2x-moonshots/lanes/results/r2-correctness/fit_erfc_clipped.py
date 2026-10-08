"""Rejected: same-cost (5-coefficient) erfc refit on a clipped range [X0, X], p scanned.

usage: python fit_erfc_clipped.py <n> <X0> <X>...  Reaches 3.5e-8 on [0.3, 3.0] but 9.5e-6 below 0.1 (erfc_fits_clipped.json).
"""
import sys, json
import numpy as np
from scipy.special import erfc

def fit(n, X, p):
    p = float(np.float32(p))
    x = np.linspace(X0, X, 40001)
    t = 1/(1+p*x)
    A = np.vander(t, n+1, increasing=True)*(np.exp(-x*x)*t)[:, None]
    b = erfc(x)
    fixed = {}
    for k in range(n, -2, -1):
        free = [i for i in range(n+1) if i not in fixed]
        if not free: break
        rhs = b - sum(A[:, i]*v for i, v in fixed.items())
        w = np.ones_like(x)
        for _ in range(40):
            c = np.linalg.lstsq(A[:, free]*np.sqrt(w)[:, None], rhs*np.sqrt(w), rcond=None)[0]
            e = np.abs(A[:, free]@c - rhs)
            w *= (e/e.max())**0.5 + 1e-3
            w /= w.sum()
        if k >= 0:
            fixed[k] = float(np.float32(c[free.index(k)]))
    coef = [fixed[i] for i in range(n+1)]
    xs = np.linspace(X0, X, 400001)
    ts = 1/(1+p*xs)
    err = ts*np.polyval(coef[::-1], ts)*np.exp(-xs*xs) - erfc(xs)
    xw = np.linspace(X, 6, 20001); tw = 1/(1+p*xw)
    errw = tw*np.polyval(coef[::-1], tw)*np.exp(-xw*xw) - erfc(xw)
    return coef, np.abs(err).max(), np.abs(errw).max()

n = int(sys.argv[1]); X0 = float(sys.argv[2]); out = {}
for X in map(float, sys.argv[3:]):
    best = None
    for p in np.arange(0.25, 0.60, 0.01):
        c, e, ew = fit(n, X, p)
        if best is None or e < best[1]: best = (p, e, ew, c)
    p, e, ew, c = best
    print(f"n={n} X={X} p={p:.2f} max err {e:.2e}  beyond X to 6 {ew:.2e}", flush=True)
    out[f"n{n}_{X0}_{X}"] = dict(p=float(np.float32(p)), c=c)
json.dump(out, open(f"fits_n{n}_{X0}.json", "w"), indent=1)

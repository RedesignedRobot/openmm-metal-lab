import numpy as np, json
from scipy.special import erfc, erfcx
def fit(p, n, X, iters=40):
    x = np.linspace(0, X, 40001)
    t = 1/(1+p*x); g = erfcx(x)/t; scale = np.exp(-x*x)*t
    A = np.vander(t, n+1, increasing=True)*scale[:,None]; b = g*scale
    w = np.ones_like(x)
    for _ in range(iters):
        c = np.linalg.lstsq(A*np.sqrt(w)[:,None], b*np.sqrt(w), rcond=None)[0]
        e = np.abs(A@c-b); w *= (e/e.max())**0.5 + 1e-3; w /= w.sum()
    return c
def err(c, p, lo, hi):
    x = np.linspace(lo, hi, 400001); t = 1/(1+p*x)
    approx = t*np.polyval(c[::-1], t)*np.exp(-x*x)
    return np.abs(approx-erfc(x)).max(), (np.abs(approx-erfc(x))/erfc(x)).max()
out = {}
for n in (5, 6):
    for X in (4.0, 6.0):
        best = min(((err(fit(p, n, X), p, 0, X)[0], p) for p in np.arange(0.25, 0.55, 0.01)))
        p = round(best[1], 2); c = fit(p, n, X)
        print(n, X, "p=%.2f" % p, "abs[0,3] %.2e  abs[0,X] %.2e  rel[0,4] %.2e  rel[4,6] %.2e" % (err(c,p,0,3)[0], err(c,p,0,X)[0], err(c,p,0,4)[1], err(c,p,4,6)[1]))
        out[f"{n}_{X}"] = dict(p=p, c=c.tolist())
json.dump(out, open('/tmp/openmm-metal-bench/ultra-r2-correctness/work/erfc_fits.json', 'w'))

"""Refit erfc(x) = t*P(t)*exp(-x*x), t = 1/(1+p*x), degree 6, with every constant a float32.

Weighted least squares (Lawson reweighting toward minimax) of the absolute error on [0, 6]. Coefficients are
rounded to float32 one at a time from the top, refitting the rest after each rounding.
"""
import numpy as np
from scipy.special import erfc, erfcx

p = float(np.float32(0.34))
n = 6
x = np.linspace(0, 6, 60001)
t = 1/(1+p*x)
scale = np.exp(-x*x)*t
A = np.vander(t, n+1, increasing=True)*scale[:, None]
b = erfcx(x)*np.exp(-x*x)
fixed = {}
for k in range(n, -2, -1):
    free = [i for i in range(n+1) if i not in fixed]
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
xs = np.linspace(0, 6, 600001)
ts = 1/(1+p*xs)
err = ts*np.polyval(coef[::-1], ts)*np.exp(-xs*xs) - erfc(xs)
print("p", repr(np.float32(p)), "coefficients", [repr(np.float32(v)) for v in coef])
print("max abs error %.2e, mean on [0.4,1.2] %.2e" % (np.abs(err).max(), err[(xs > 0.4) & (xs < 1.2)].mean()))

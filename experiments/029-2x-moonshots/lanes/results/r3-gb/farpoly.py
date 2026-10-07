"""Far-region OBC descreening as a polynomial in y = (S/r)^2. For r >= R+S the Born-sum term is invR*x^3*P(y) and
the chain-rule term1 of gbsaObc2.cc is invR^3*x^3*Q(y), x = S/r. Fits P and Q by Chebyshev least squares on
[0, XMAX^2], checks float32 Horner against float64 closed forms, and counts SIMD iterations with a near lane."""
import os, sys
import numpy as np
XMAX = float(os.environ.get("XMAX", "0.6"))
def P_exact(y):
    x = np.sqrt(y)
    return (1/(1-x)-1/(1+x)+0.5*np.log((1-x)/(1+x))+0.25*(1-y)*(1/(1+x)**2-1/(1-x)**2))/x**3
def Q_exact(y):
    x = np.sqrt(y)
    return (0.5*x*(1+y)/(1-y)**2+0.25*np.log((1-x)/(1+x)))/x**3
def series(y, c):
    return sum(ck*y**k for k, ck in enumerate(c))
# The closed forms cancel badly for small x even in float64, so fit against the series there.
def P_ref(y):
    small = y < 0.01
    s = series(y, [2*k/(2*k+1) for k in range(1, 40)])
    return np.where(small, s, P_exact(np.maximum(y, 1e-6)))
def Q_ref(y):
    small = y < 0.01
    s = series(y, [2*m*(m+1)/(2*m+1) for m in range(1, 40)])
    return np.where(small, s, Q_exact(np.maximum(y, 1e-6)))
y = np.linspace(0, XMAX**2, 200001)
for name, ref in [("P", P_ref), ("Q", Q_ref)]:
    fy = ref(y)
    for deg in range(5, 13):
        cheb = np.polynomial.chebyshev.Chebyshev.fit(y, fy, deg, domain=[0, XMAX**2])
        c = cheb.convert(kind=np.polynomial.Polynomial).coef.astype(np.float32)
        acc = np.zeros_like(y, dtype=np.float32); yf = y.astype(np.float32)
        for ck in c[::-1]:
            acc = acc*yf+ck
        err = np.abs(acc.astype(np.float64)-fy)/np.abs(fy)
        print(f"{name} XMAX {XMAX} degree {deg:2d}: float32 Horner max rel err {err.max():.2e}  coef {' '.join('%.9g' % v for v in c)}" if deg in (7, 8, 9, 10) else f"{name} degree {deg:2d}: max rel err {err.max():.2e}")

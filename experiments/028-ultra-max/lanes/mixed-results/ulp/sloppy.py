import numpy as np
from fractions import Fraction
f = np.float32
rng = np.random.default_rng(1)

def two_sum(a, b):
    s = f(a + b); bb = f(s - a)
    return s, f(f(a - f(s - bb)) + f(b - bb))

def fast_two_sum(a, b):
    s = f(a + b)
    return s, f(b - f(s - a))

def df(v):
    hi = f(v); lo = f(v - float(hi))
    return hi, lo

def sloppy(xh, xl, yh, yl):
    sx, sy = two_sum(xh, yh)
    return fast_two_sum(sx, f(sy + f(xl + yl)))

worst = 0.0
for case in ("uniform", "cancel", "mixed-scale"):
    for _ in range(100000):
        a = rng.uniform(-10, 10)
        if case == "uniform":
            b = rng.uniform(-10, 10)
        elif case == "cancel":
            b = -a + rng.uniform(-1e-5, 1e-5)
        else:
            b = rng.uniform(-10, 10) * 10.0 ** rng.uniform(-8, 0)
        xh, xl = df(a); yh, yl = df(b)
        zh, zl = sloppy(xh, xl, yh, yl)
        exact = Fraction(float(xh)) + Fraction(float(xl)) + Fraction(float(yh)) + Fraction(float(yl))
        err = abs(Fraction(float(zh)) + Fraction(float(zl)) - exact)
        scale = abs(Fraction(float(xh))) + abs(Fraction(float(yh)))
        worst = max(worst, float(err / scale) * 2.0 ** 47)
    print(case, "max error / (|x|+|y|) in units of 2^-47:", round(worst, 3))

# Compare two dumpforces.py outputs: max |dF| and |dE| per system.
import sys, numpy as np
a, b = np.load(sys.argv[1]), np.load(sys.argv[2])
for k in a.files:
    if k.endswith('-f'):
        d = np.abs(a[k]-b[k]).max()
        e = abs(float(a[k[:-1]+'e'])-float(b[k[:-1]+'e']))
        print(f"{k[:-2]:20s} max|dF| {d:.3e}  |dE| {e:.3e}  identical={np.array_equal(a[k], b[k])}")

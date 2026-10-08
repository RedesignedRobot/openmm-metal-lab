# Compare dumpd3.py outputs bit for bit.  Usage: cmpd3.py A.npz B.npz...  Every file is compared with the first.
import sys, numpy as np
ref = np.load(sys.argv[1])
bad = 0
for other in sys.argv[2:]:
    b = np.load(other)
    for k in ref.files:
        same = np.array_equal(ref[k], b[k])
        bad += not same
        d = float(np.abs(ref[k]-b[k]).max())
        print(f"{other.split('/')[-1]:14s} {k:28s} identical={same} max|d| {d:.3e}")
print('ALL IDENTICAL' if bad == 0 else f'{bad} MISMATCHES')

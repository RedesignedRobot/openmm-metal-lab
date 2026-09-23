"""Compare two eqcheck.py outputs: the old kernel (before) against the new one (after).

usage: python compare.py <before.npz> <after.npz>
For each case, prints the difference between the two installs next to the difference between two
fresh Contexts of the before install, which is the rounding floor to compare it with.
"""
import sys

import numpy as np

before, after = np.load(sys.argv[1]), np.load(sys.argv[2])
cases = sorted({key.split("/")[0] for key in before.files}, key=lambda k: before.files.index(f"{k}/forces1"))


def diff(fa, ea, fb, eb):
    rel_force = np.linalg.norm(fa-fb)/np.linalg.norm(fa)
    return f"{np.abs(fa-fb).max():10.3e} {rel_force:10.3e} {abs(ea-eb):10.3e} {abs(ea-eb)/abs(ea):10.3e} {str(np.array_equal(fa, fb) and ea == eb):>5}"


print(f"{'case':15} {'energy before':>16} {'energy after':>16} | before vs after: {'max|dF|':>10} {'rel|dF|':>10} {'|dE|':>10} {'rel|dE|':>10} {'same':>5}"
      f" | before vs before: {'max|dF|':>10} {'rel|dF|':>10} {'|dE|':>10} {'rel|dE|':>10} {'same':>5}")
for case in cases:
    f1, e1 = before[f"{case}/forces1"], float(before[f"{case}/energy1"])
    f2, e2 = before[f"{case}/forces2"], float(before[f"{case}/energy2"])
    g1, h1 = after[f"{case}/forces1"], float(after[f"{case}/energy1"])
    print(f"{case:15} {e1:16.4f} {h1:16.4f} | {'':17}{diff(f1, e1, g1, h1)} | {'':18}{diff(f1, e1, f2, e2)}")

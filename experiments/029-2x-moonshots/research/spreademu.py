"""CPU count of PME spread atomics per SIMD block: distinct grid points touched by 32 consecutive
atoms (Metal atom order from accum-nb's emu.reorder) against 32*125 scatter adds. No GPU."""
import sys, math, numpy as np
sys.path.insert(0, '/tmp/openmm-metal-bench/ultra-r2-accum-nb/emu')
import emu

def legal(n):
    while True:
        m = n
        for p in (2, 3, 5, 7):
            while m % p == 0: m //= p
        if m == 1: return n
        n += 1

test = sys.argv[1]
system, pos0, box, params = emu.load(test)
import openmm as mm
nb = [f for f in system.getForces() if isinstance(f, mm.NonbondedForce)][0]
cut = nb.getCutoffDistance()._value
tol = nb.getEwaldErrorTolerance()
alpha = math.sqrt(-math.log(2*tol))/cut
L = np.diag(box)
dims = [legal(int(math.ceil(2*alpha*l/(3*tol**0.2)))) for l in L]
order = emu.reorder(system, pos0, box)
pos = pos0[order]
pos = pos - np.floor(pos/L)*L
u = pos/L*np.array(dims)
base = np.floor(u).astype(np.int64)
n = len(pos)
ORDER = 5
off = np.arange(ORDER)
res = {}
for B in (32, 64, 256):
    uniq = 0; blocks = 0
    for s in range(0, n, B):
        b = base[s:s+B]
        gx = (b[:, 0:1] + off) % dims[0]
        gy = (b[:, 1:2] + off) % dims[1]
        gz = (b[:, 2:3] + off) % dims[2]
        idx = (gx[:, :, None, None]*dims[1] + gy[:, None, :, None])*dims[2] + gz[:, None, None, :]
        uniq += len(np.unique(idx.ravel())); blocks += 1
    res[B] = (n*125)/uniq
print(f"{test} atoms {n} grid {dims} alpha {alpha:.3f} spacing {L[0]/dims[0]:.4f} nm; scatter adds / distinct points per block: " + ", ".join(f"B={B} {r:.2f}x" for B, r in res.items()))
# Bounding box of the 32-atom block's stencil, in grid points per dimension (wrap-aware via
# minimum-image relative to the first atom), for the column-owner check budget.
ext = []
for s in range(0, n, 32):
    b = base[s:s+32]
    d = b - b[0]
    d = d - np.round(d/np.array(dims)).astype(np.int64)*np.array(dims)
    ext.append(d.max(0) - d.min(0) + ORDER)
ext = np.array(ext)
print(f"  bbox per 32-block: mean {ext.mean(0).round(1)}, p90 {np.percentile(ext,90,axis=0)}, mean volume {np.prod(ext,1).mean():.0f}, mean columns {(ext[:,1]*ext[:,2]).mean():.0f}")

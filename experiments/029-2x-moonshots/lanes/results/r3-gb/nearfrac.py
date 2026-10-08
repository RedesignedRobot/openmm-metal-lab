"""How often a SIMD iteration of the owned Born sum has a lane outside the far-region polynomial's domain."""
import os, sys
import numpy as np
os.chdir("/tmp/openmm-metal-bench/ultra-base/benchmarks")
source = open("benchmark.py").read()
sys.argv = ["benchmark.py"]
exec(source[:source.index("def serializeTest")])
import openmm as mm, openmm.unit as u
XMAX = float(os.environ.get("XMAX", "0.6"))
system, positions, _ = retrieveTestSystem("gbsa")
gb = [f for f in system.getForces() if isinstance(f, mm.GBSAOBCForce)][0]
n = gb.getNumParticles()
R = np.zeros(n); S = np.zeros(n)
for i in range(n):
    q, rad, s = gb.getParticleParameters(i)
    rad = rad.value_in_unit(u.nanometer)
    R[i] = rad-0.009; S[i] = R[i]*s
print("max S/(R_i+S_j) over atom kinds", max(S[j]/(R[i]+S[j]) for i in set(np.unique(R, return_index=True)[1]) for j in set(np.unique(S, return_index=True)[1])))
pos = np.array(positions.value_in_unit(u.nanometer))
pad = (n+31)//32*32
P = np.full((pad, 3), 1e6); P[:n] = pos
Rp = np.ones(pad); Rp[:n] = R; Sp = np.ones(pad); Sp[:n] = S
nb = pad//32
tgx = np.arange(32)
iters = anynear = lanes = nearlanes = 0
for x in range(nb):
    for y in range(x, nb):
        a = x*32+tgx
        for j in range(32):
            b = y*32+((tgx+j) & 31)
            if x == y:
                b = x*32+j+0*tgx
            d = np.linalg.norm(P[a]-P[b], axis=1)
            valid = (a < n) & (b < n) & (a != b) & (d < 2.0)
            if not valid.any():
                continue
            far = (d >= Rp[a]+Sp[b]) & (Sp[b] <= XMAX*d) & (d >= Rp[b]+Sp[a]) & (Sp[a] <= XMAX*d)
            iters += 1
            lanes += valid.sum()
            nearlanes += (valid & ~far).sum()
            anynear += (valid & ~far).any()
print(f"XMAX {XMAX}: iterations with a valid lane {iters}, with a near lane {anynear} ({100*anynear/iters:.2f}%); lanes near {nearlanes}/{lanes} ({100*nearlanes/lanes:.3f}%)")

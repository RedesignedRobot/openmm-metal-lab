"""Radial-table accuracy study (consult idea 2), CPU only. For every distinct (offset radius i, scaled radius j) pair
in gbsa, compare the float32 analytic Born-sum term and a cubic Hermite table in float32 against float64 analytic
values, on a dense r grid over (0, cutoff)."""
import os, sys
import numpy as np
os.chdir("/tmp/openmm-metal-bench/ultra-base/benchmarks")
source = open("benchmark.py").read()
sys.argv = ["benchmark.py"]
exec(source[:source.index("def serializeTest")])
import openmm as mm
system, positions, _ = retrieveTestSystem("gbsa")
gb = [f for f in system.getForces() if isinstance(f, mm.GBSAOBCForce)][0]
cut = gb.getCutoffDistance().value_in_unit(mm.unit.nanometer) if hasattr(gb.getCutoffDistance(), "value_in_unit") else gb.getCutoffDistance()
off, scl = [], []
for i in range(gb.getNumParticles()):
    q, rad, s = gb.getParticleParameters(i)
    rad = rad.value_in_unit(mm.unit.nanometer) if hasattr(rad, "value_in_unit") else rad
    off.append(rad-0.009); scl.append((rad-0.009)*s)
off = np.array(off); scl = np.array(scl)
types = sorted(set(zip(np.round(off, 7), np.round(scl, 7))))
oset = sorted(set(np.round(off, 7))); sset = sorted(set(np.round(scl, 7)))
print(f"atoms {len(off)} distinct (offset, scaled) types {len(types)}; offsets {len(oset)}, scaled {len(sset)}; directed pair kinds {len(oset)*len(sset)}; cutoff {cut}")

def term(r, R1, S2, dt):
    r = r.astype(dt); R1 = dt(R1); S2 = dt(S2)
    invR = dt(1)/r
    rs = r+S2
    L = np.maximum(R1, np.abs(r-S2))
    l = dt(1)/L; uu = dt(1)/rs
    t = l-uu+dt(0.5)*invR*np.log(uu*L)+dt(0.25)*(r*(uu*uu-l*l)+(S2*S2*invR)*(l*l-uu*uu))
    t = t+np.where(R1 < S2-r, dt(2)*(dt(1)/R1-l), dt(0))
    return np.where(R1 >= rs, dt(0), t)

def dterm(r, R1, S2):
    h = 1e-7*np.maximum(r, 1e-3)
    return (term(r+h, R1, S2, np.float64)-term(r-h, R1, S2, np.float64))/(2*h)

rg = np.linspace(0.05, cut, 400001)
def hermite(nodes, R1, S2, x):
    fv = term(nodes, R1, S2, np.float64); dv = dterm(nodes, R1, S2)
    k = np.clip(np.searchsorted(nodes, x, side="right")-1, 0, len(nodes)-2)
    h = nodes[k+1]-nodes[k]
    t = (x-nodes[k])/h
    h00 = 2*t**3-3*t**2+1; h10 = t**3-2*t**2+t; h01 = -2*t**3+3*t**2; h11 = t**3-t**2
    return (h00*fv[k]+h10*h*dv[k]+h01*fv[k+1]+h11*h*dv[k+1]).astype(np.float32).astype(np.float64)
for N in [64, 256, 1024]:
    ef, et = [], []
    for R1 in oset:
        for S2 in sset:
            exact = term(rg, R1, S2, np.float64)
            scale = np.abs(exact).max()
            if scale == 0:
                continue
            kinks = sorted({k for k in (R1-S2, S2-R1, S2+R1) if 0.05 < k < cut})
            # Nodes uniform in 1/r between kinks (the term falls like r^-4), N in all.
            edges = [0.05]+kinks+[cut]
            nodes = []
            for a, b in zip(edges[:-1], edges[1:]):
                m = max(2, int(round(N*(1/a-1/b)/(1/0.05-1/cut))))
                nodes.extend(1/np.linspace(1/a, 1/b, m+1)[:-1])
            nodes = np.array(nodes+[cut])
            tab = hermite(nodes, R1, S2, rg)
            ef.append(np.abs(term(rg, R1, S2, np.float32).astype(np.float64)-exact).max()/scale)
            et.append(np.abs(tab-exact).max()/scale)
    print(f"N~{N:5d} kink-aligned, 1/r spacing: float32 analytic {max(ef):.2e}, table {max(et):.2e} (median {np.median(et):.2e}); bytes {len(oset)*len(sset)*(N+4)*8}")

"""Counts SHAKE sweeps per gbsa cluster in float64 for the fused quads kernel's Gauss-Seidel sweep and for a Jacobi
sweep (every constraint from the same start-of-sweep center, updates summed), position and velocity SHAKE.

The kernel runs one cluster per quad, 8 quads per SIMD group, clusters in central-atom order. A SIMD group pays
max-sweeps times max-bonds for Gauss-Seidel (the bonds are a serial chain) and max-sweeps for Jacobi (one bond per
lane, then a quad reduction). Snapshots come from CPU-platform steps of benchmark.py's gbsa system."""
import os, sys
import numpy as np
import openmm as mm
import openmm.unit as unit
from collections import defaultdict, Counter

os.chdir("/tmp/openmm-metal-bench/ultra-base/benchmarks")
source = open("benchmark.py").read()
exec(source[:source.index("def serializeTest")])
system, positions, _ = retrieveTestSystem("gbsa")
dt, gamma, kT, tol, cap = 0.004, 91.0, 2.494, 1e-5, 15
integ = mm.LangevinMiddleIntegrator(300, gamma, dt)
integ.setConstraintTolerance(tol)
ctx = mm.Context(system, integ, mm.Platform.getPlatformByName("CPU"), {"Threads": "4"})
ctx.setPositions(positions)
ctx.setVelocitiesToTemperature(300, 1)
integ.step(200)
m = np.array([system.getParticleMass(i).value_in_unit(unit.dalton) for i in range(system.getNumParticles())])
im = np.where(m > 0, 1/np.where(m > 0, m, 1), 0)

nb = defaultdict(list); d = {}
for k in range(system.getNumConstraints()):
    i, j, dist = system.getConstraintParameters(k)
    nb[i].append(j); nb[j].append(i); d[(i, j)] = d[(j, i)] = dist.value_in_unit(unit.nanometer)
seen = set(); clusters = []
for a in sorted(nb, key=lambda a: -len(nb[a])):
    if a in seen: continue
    members = [b for b in nb[a] if b not in seen]
    if not members: continue
    clusters.append((a, members)); seen.add(a); seen.update(members)
clusters.sort()


def pos_shake(a, js, x, delta, jacobi):
    invC, invP = im[a], im[js[0]]
    avg = 0.5/(invC+invP)
    d2 = d[(a, js[0])]**2
    xpi = delta[a].copy(); xpj = [delta[j].copy() for j in js]
    rij = [x[a]-x[j] for j in js]
    ld = [d2-r@r for r in rij]
    it = 0
    while it < cap:
        it += 1
        center = xpi.copy()
        moved = False
        for k in range(len(js)):
            rp = (center if jacobi else xpi)-xpj[k]
            res = ld[k]-2*(rij[k]@rp)-rp@rp
            if abs(res) >= d2*tol:
                dr = rij[k]*(res*avg/((rij[k]@rp)+rij[k]@rij[k]))
                xpi += dr*invC; xpj[k] -= dr*invP; moved = True
        if not moved:
            return it
    return it


def vel_shake(a, js, x, v, jacobi):
    invC, invP = im[a], im[js[0]]
    avg = 0.5/(invC+invP)
    xpi = v[a].copy(); xpj = [v[j].copy() for j in js]
    rij = [x[a]-x[j] for j in js]
    it = 0
    while it < cap:
        it += 1
        center = xpi.copy()
        conv = True
        for k in range(len(js)):
            rp = (center if jacobi else xpi)-xpj[k]
            dl = -2*avg*(rp@rij[k])/(rij[k]@rij[k])
            dr = rij[k]*dl
            xpi += dr*invC; xpj[k] -= dr*invP
            if abs(dl) > tol:
                conv = False
        if conv:
            return it
    return it


def pos_newton(a, js, x, delta):
    """Newton on the multipliers: each sweep solves the linearized n x n system at the current point (M-SHAKE)."""
    invC, invP = im[a], im[js[0]]
    d2 = d[(a, js[0])]**2
    xpi = delta[a].copy(); xpj = [delta[j].copy() for j in js]
    rij = [x[a]-x[j] for j in js]
    ld = [d2-r@r for r in rij]
    n = len(js)
    it = 0
    while it < cap:
        it += 1
        rp = [xpi-xpj[k] for k in range(n)]
        res = np.array([ld[k]-2*(rij[k]@rp[k])-rp[k]@rp[k] for k in range(n)])
        if np.all(np.abs(res) < d2*tol):
            return it
        J = np.array([[-2*(rij[k]+rp[k])@(rij[l]*invC+(rij[l]*invP if k == l else 0)) for l in range(n)] for k in range(n)])
        lam = np.linalg.solve(J, -res)
        for k in range(n):
            xpi += lam[k]*rij[k]*invC; xpj[k] -= lam[k]*rij[k]*invP
    return it


rng = np.random.default_rng(1)
vscale = np.exp(-dt*gamma); noise = np.sqrt(kT*(1-vscale*vscale))
stats = {key: [] for key in ("vel-gs", "vel-j", "pos-gs", "pos-j", "pos-nt")}
for snap in range(5):
    integ.step(20)
    st = ctx.getState(positions=True, velocities=True, forces=True)
    x = st.getPositions(asNumpy=True).value_in_unit(unit.nanometer)
    v = st.getVelocities(asNumpy=True).value_in_unit(unit.nanometer/unit.picosecond)
    f = st.getForces(asNumpy=True).value_in_unit(unit.kilojoule_per_mole/unit.nanometer)
    vv = v + dt*f*im[:, None]
    delta = 0.5*dt*vv
    vb = vscale*vv + noise*np.sqrt(im)[:, None]*rng.standard_normal(vv.shape)
    delta = delta + 0.5*dt*vb
    for a, js in clusters:
        nbonds = len(js)
        stats["vel-gs"].append((nbonds, vel_shake(a, js, x, vv, False)))
        stats["vel-j"].append((nbonds, vel_shake(a, js, x, vv, True)))
        stats["pos-gs"].append((nbonds, pos_shake(a, js, x, delta, False)))
        stats["pos-j"].append((nbonds, pos_shake(a, js, x, delta, True)))
        stats["pos-nt"].append((nbonds, pos_newton(a, js, x, delta)))

n = len(clusters)
print("%d clusters, bonds per cluster %s, 5 snapshots, tol %g, cap %d" % (n, dict(Counter(len(js) for _, js in clusters)), tol, cap))
for key, rows in stats.items():
    arr = np.array(rows).reshape(5, n, 2)
    b, s = arr[..., 0], arr[..., 1]
    groups = [(g, min(g+8, n)) for g in range(0, n, 8)]
    gmax_s = np.array([[s[t, lo:hi].max() for lo, hi in groups] for t in range(5)])
    gmax_b = np.array([[b[t, lo:hi].max() for lo, hi in groups] for t in range(5)])
    chain = gmax_s*(gmax_b if key.endswith("gs") else 1)
    hit = (s >= cap).sum()
    print("%-6s sweeps mean %.2f max %d; hist %s; capped %d" % (key, s.mean(), s.max(), dict(sorted(Counter(s.ravel().tolist()).items())), hit))
    print("       per SIMD group: max sweeps mean %.2f; serial chain (sweeps x bonds for GS) mean %.2f" % (gmax_s.mean(), chain.mean()))

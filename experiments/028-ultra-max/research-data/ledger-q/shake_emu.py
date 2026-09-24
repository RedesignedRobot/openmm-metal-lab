# CPU emulation of applyShakeToPositions: base mixed loop vs c3 (933483458) float warm start + mixed loop.
# mixed = IEEE double here (Metal's mixed is df64, about 48 bits), real = float32 via struct rounding.
import math, random, struct, sys
def f(x): return struct.unpack('f', struct.pack('f', x))[0]
def v3(a,b,c): return [a,b,c]
def add(a,b): return [a[i]+b[i] for i in range(3)]
def sub(a,b): return [a[i]-b[i] for i in range(3)]
def mul(a,s): return [a[i]*s for i in range(3)]
def dot(a,b): return a[0]*b[0]+a[1]*b[1]+a[2]*b[2]
def fadd(a,b): return [f(a[i]+b[i]) for i in range(3)]
def fsub(a,b): return [f(a[i]-b[i]) for i in range(3)]
def fmul(a,s): return [f(a[i]*s) for i in range(3)]
def fdot(a,b): return f(f(f(a[0]*b[0])+f(a[1]*b[1]))+f(a[2]*b[2]))

def mixed_loop(r, ld, rsq, xp, n, d2, tol, avgMass, imc, imp):
    it = 0; conv = False
    while it < 15 and not conv:
        conv = True
        for k in range(n):
            rp = sub(xp[0], xp[k+1]); rrpr = dot(r[k], rp); res = ld[k]-2.0*rrpr-dot(rp,rp)
            if abs(res)/(d2*tol) >= 1.0:
                acor = res*avgMass/(rrpr+rsq[k]); dr = mul(r[k], acor)
                xp[0] = add(xp[0], mul(dr, imc)); xp[k+1] = sub(xp[k+1], mul(dr, imp)); conv = False
        it += 1
    return it

def warm(r, ld, rsq, xp, n, d2, tol, avgMass, imc, imp):
    rf = [[f(c) for c in r[k]] for k in range(n)]
    rp0 = [[f(xp[0][i]-xp[k+1][i]) for i in range(3)] for k in range(n)]
    dx = [[0.0]*3 for _ in range(n+1)]
    maxRes = f(d2*f(tol)); realRes = max(maxRes, f(1e-7*d2))
    for it in range(15):
        done = True
        for k in range(n):
            rpij = fsub(fadd(rp0[k], dx[0]), dx[k+1]); rrpr = fdot(rf[k], rpij)
            res = f(f(f(ld[k]) - f(2.0*rrpr)) - fdot(rpij, rpij))
            if abs(res) >= realRes:
                dr = fmul(rf[k], f(f(res*avgMass)/f(rrpr+f(rsq[k]))))
                dx[0] = fadd(dx[0], fmul(dr, imc)); dx[k+1] = fsub(dx[k+1], fmul(dr, imp)); done = False
        if done: break
    for k in range(n+1): xp[k] = add(xp[k], dx[k])

def run(nclusters, nh, tol, sigma, seed):
    rnd = random.Random(seed)
    d = 0.1090; d2 = f(d*d)  # clusterParams.z is float
    mc, mh = 12.011, 1.008; imc, imp = f(1/mc), f(1/mh); avgMass = f(0.5/(1/mc+1/mh))
    stats = {'base': [], 'warm': []}; resid = {'base': [], 'warm': []}; iters = {'base': [], 'warm': []}
    for c in range(nclusters):
        # old positions satisfy the constraint to about 1e-9 relative
        dirs = []
        for k in range(nh):
            u = [rnd.gauss(0,1) for _ in range(3)]; nu = math.sqrt(dot(u,u)); dirs.append(mul(u, d*(1+rnd.uniform(-5e-9,5e-9))/nu))
        pos = [[rnd.uniform(0,5) for _ in range(3)]]
        for k in range(nh): pos.append(sub(pos[0], dirs[k]))
        # oldPos is float posq plus float correction: exact to about 2^-48, use double
        r = [sub(pos[0], pos[k+1]) for k in range(nh)]; rsq = [dot(x,x) for x in r]; ld = [d2-x for x in rsq]
        delta = [[rnd.gauss(0, sigma*(1 if k==0 else 3.4)) for _ in range(3)] for k in range(nh+1)]
        for mode in ('base', 'warm'):
            xp = [list(x) for x in delta]
            if mode == 'warm': warm(r, ld, rsq, xp, nh, d2, tol, avgMass, imc, imp)
            iters[mode].append(mixed_loop(r, ld, rsq, xp, nh, d2, tol, avgMass, imc, imp))
            for k in range(nh):
                rn = add(r[k], sub(xp[0], xp[k+1])); L = math.sqrt(dot(rn,rn))
                stats[mode].append(abs(L-d)/d)
                resid[mode].append(abs(d2-dot(rn,rn))/(d2*tol))
    return stats, resid, iters

tol = float(sys.argv[1]) if len(sys.argv) > 1 else 1e-8
for nh in (1, 3):
    s, rs, it = run(4000, nh, tol, 0.0015, 7+nh)
    for m in ('base', 'warm'):
        v = sorted(s[m]); rr = sorted(rs[m]); n = len(v)
        print(f"tol {tol:g} nH {nh} {m:4}: max rel len err {v[-1]:.3e}  p99 {v[int(.99*n)]:.3e}  median {v[n//2]:.3e} | exit residual/tol median {rr[n//2]:.3f} p90 {rr[int(.9*n)]:.3f} max {rr[-1]:.3f} | mixed iters mean {sum(it[m])/len(it[m]):.2f}")

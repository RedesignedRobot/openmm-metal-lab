# Block-pair work for the owned GB kernels under different atom orders (DHFR gbsa, cutoff 2.0 nm).
import numpy as np, sys
xyz = np.array([[float(l[30:38]), float(l[38:46]), float(l[46:54])] for l in open(sys.argv[1]) if l.startswith(('ATOM', 'HETATM'))])/10
n = len(xyz); T = 32; nb = (n+T-1)//T; cut2 = 2.0**2

def morton(p):
    q = ((p-p.min(0))/(np.ptp(p, 0).max())*1023).astype(np.int64)
    code = np.zeros(len(p), np.int64)
    for b in range(10):
        for d in range(3):
            code |= ((q[:, d] >> b) & 1) << (3*b+d)
    return np.argsort(code, kind='stable')

def rcb(idx, p):
    if len(idx) <= T: return [idx]
    d = np.ptp(p[idx], 0).argmax()
    s = idx[np.argsort(p[idx, d], kind='stable')]
    nblk = (len(s)+T-1)//T; h = (nblk//2)*T
    return rcb(s[:h], p) + rcb(s[h:], p)

def stats(order):
    p = xyz[order]
    pad = np.full((nb*T, 3), np.nan); pad[:n] = p
    blk = pad.reshape(nb, T, 3)
    lo = np.nanmin(blk, 1); hi = np.nanmax(blk, 1); c = (lo+hi)/2; s = (hi-lo)/2
    kept = inr = act = 0
    for x in range(nb):
        for y in range(x, nb):
            d = np.maximum(0, np.abs(c[x]-c[y])-s[x]-s[y])
            if (d*d).sum() >= cut2: continue
            kept += 1
            a = blk[x]; b = blk[y]
            if x == y:
                r2 = ((a[:, None]-b[None])**2).sum(-1)
                ok = np.nan_to_num(r2, nan=1e9) < cut2
                inr += ok.sum(); act += ok.any(0).sum()
            else:
                for j in range(T):
                    bb = np.roll(b, -j, 0)
                    ok = np.nan_to_num(((a-bb)**2).sum(-1), nan=1e9) < cut2
                    inr += 2*ok.sum(); act += ok.any()
    total = nb*(nb+1)//2
    print(f"kept {kept}/{total} pairs, in-range lane fraction {inr/(kept*T*T*1.0 + (kept - 0)*0) :.3f} (both sides), active steps {act}/{kept*T} = {act/(kept*T):.3f}, useful pair evals per kept step {inr/2/(kept*T)/T:.3f}")

print(n, "atoms", nb, "blocks")
print("pdb order:   ", end=""); stats(np.arange(n))
print("morton:      ", end=""); stats(morton(xyz))
print("rcb:         ", end=""); stats(np.concatenate(rcb(np.arange(n), xyz)))

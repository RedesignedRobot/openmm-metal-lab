"""Q1 shadow crossing replay, off the GPU, on the recorded apoa1rf trajectory (eff/moves-<prec>.npz, 600 steps).

For each list build (the recorded rebuild steps), the list is built from the positions before that step, and at age k
the force evaluation sees the positions k steps later. At ages 2-4 this counts:
  crossings: pairs with r(t0) >= rc+p and r(t) < rc, the pairs a list built at t0 could miss (sufficient condition);
  over: atoms that moved more than p/2 (the half-padding test fails when this is above zero);
  uncertified: block pairs with D_A+D_B > p whose current bounding boxes come within rc (the verifier's scan).
Blocks are 32 consecutive atoms in the Metal order dumped at the benchmark start (eff/apoa1rf/order.i32).
Cutoff and padding come from the command line, so the RF trajectory can stand in for PME's 0.9 nm / 0.072 nm.
usage: shadow.py <prec> <rc> <p> [epoch stride]"""
import json
import sys
from pathlib import Path
import numpy as np
from scipy.spatial import cKDTree

eff = Path("/tmp/openmm-metal-bench/ultra-r2-accum-nb/eff")
prec, rc, p = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
stride = int(sys.argv[4]) if len(sys.argv) > 4 else 4
rec = np.load(eff/f"moves-{prec}.npz")
start, moves, flags = rec["start"], rec["moves"], rec["flags"]
box = np.load(eff/"apoa1rf/state.npz")["box"]
order = np.fromfile(eff/"apoa1rf/order.i32", dtype=np.int32)
N = len(start)
order = order[:N]
T = 32
nb = (N+T-1)//T

def pos(s):
    return start+moves[s].astype(np.float64)

def mic(d):
    return d-box*np.round(d/box)

builds = [s for s in np.flatnonzero(flags) if s >= 1 and s-1+4 < len(moves)][::stride]
rows = []
for s in builds:
    p0 = pos(s-1)
    for age in (2, 3, 4):
        pt = pos(s-1+age)
        u = pt-p0
        d = np.sqrt((u*u).sum(1))
        fast = np.flatnonzero(d > p/2)
        # Crossings: |u_i-u_j| > p is needed, so one end moved more than p/2.
        cross = 0
        if len(fast):
            tree = cKDTree(pt % box, boxsize=box)
            nbrs = tree.query_ball_point(pt[fast] % box, rc)
            seen = set()
            for i, js in zip(fast, nbrs):
                js = np.asarray(js)
                js = js[js != i]
                if len(js) == 0:
                    continue
                r0 = np.sqrt((mic(p0[js]-p0[i])**2).sum(1))
                for j in js[r0 >= rc+p]:
                    seen.add((min(i, j), max(i, j)))
            cross = len(seen)
        # Block displacement maxima and current bounding boxes, in the Metal atom order.
        do = np.zeros(nb*T); do[:N] = d[order]
        D = do.reshape(nb, T).max(1)
        po = pt[order]
        lo = np.full((nb, 3), np.inf); hi = np.full((nb, 3), -np.inf)
        for b in range(nb):
            q = po[b*T:(b+1)*T]
            q = q[0]+mic(q-q[0])
            lo[b], hi[b] = q.min(0), q.max(0)
        c, h = (lo+hi)/2, (hi-lo)/2
        a_idx, b_idx = np.triu_indices(nb, 1)
        keep = D[a_idx]+D[b_idx] > p
        a_idx, b_idx = a_idx[keep], b_idx[keep]
        gap = np.maximum(0, np.abs(mic(c[b_idx]-c[a_idx]))-h[a_idx]-h[b_idx])
        near = (gap*gap).sum(1) < rc*rc
        two = np.sort(d)[-2:].sum()
        rows.append(dict(build=int(s), age=age, crossings=cross, over=int(len(fast)), max=float(d.max()),
                         two_largest=float(two), blocks_over=int((D > p/2).sum()),
                         uncertified_pairs=int(near.sum())))
        print(json.dumps(rows[-1]), flush=True)

summary = {}
for age in (2, 3, 4):
    r = [x for x in rows if x["age"] == age]
    summary[age] = dict(epochs=len(r), crossings_mean=float(np.mean([x["crossings"] for x in r])),
                        epochs_with_crossing=sum(x["crossings"] > 0 for x in r),
                        over_mean=float(np.mean([x["over"] for x in r])),
                        two_largest_ok=sum(x["two_largest"] <= p for x in r),
                        uncertified_pairs_mean=float(np.mean([x["uncertified_pairs"] for x in r])))
print(json.dumps(dict(prec=prec, rc=rc, p=p, summary=summary), indent=1))

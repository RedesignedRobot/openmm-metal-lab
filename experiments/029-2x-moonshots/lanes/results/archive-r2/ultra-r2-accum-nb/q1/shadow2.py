"""Q1 shadow crossing replay on the dump.py trajectories (q1/traj-<test>.npz): float32 positions, the Metal atom
order and the rebuild flag at every step of two 150-step windows.

A list flagged as rebuilt at step s was built from the positions before step s (pos[s-1]); at age k the force
evaluation sees pos[s-1+k]. For each build and ages 2-4 it counts:
  crossings: pairs with r(t0) >= rc+p and r(t) < rc (a sufficient condition for a pair the list could miss);
  over: atoms that moved more than p/2 since the build (the half-padding test fails when this is above zero);
  uncertified: block pairs with D_A+D_B > p whose current bounding boxes come within rc (the verifier's scan),
  against the block pairs whose boxes at the build come within rc+p (the builder's scan).
Blocks are 32 consecutive atoms in the Metal order of the build step.
usage: shadow2.py <test> [padding fraction of the cutoff, default 0.08]"""
import json
import sys
from pathlib import Path
import numpy as np
from scipy.spatial import cKDTree

q1 = Path("/tmp/openmm-metal-bench/ultra-r2-accum-nb/q1")
test = sys.argv[1]
z = np.load(q1/f"traj-{test}.npz")
box, rc = z["box"], float(z["cutoff"])
p = (float(sys.argv[2]) if len(sys.argv) > 2 else 0.08)*rc
T = 32

def mic(d):
    return d-box*np.round(d/box)

def blocks(po):
    nb = (len(po)+T-1)//T
    lo = np.empty((nb, 3)); hi = np.empty((nb, 3))
    for b in range(nb):
        q = po[b*T:(b+1)*T]
        q = q[0]+mic(q-q[0])
        lo[b], hi[b] = q.min(0), q.max(0)
    return (lo+hi)/2, (hi-lo)/2

def near_pairs(c, h, a, b, r):
    gap = np.maximum(0, np.abs(mic(c[b]-c[a]))-h[a]-h[b])
    return (gap*gap).sum(1) < r*r

rows = []
for w in (0, 1):
    pos, order, flags = z[f"pos{w}"].astype(np.float64), z[f"order{w}"], z[f"flags{w}"]
    for s in np.flatnonzero(flags):
        if s < 1 or s-1+4 >= len(pos):
            continue
        p0, o = pos[s-1], order[s-1]
        nb = (len(o)+T-1)//T
        a_all, b_all = np.triu_indices(nb, 1)
        c0, h0 = blocks(p0[o])
        rebuild_pairs = int(near_pairs(c0, h0, a_all, b_all, rc+p).sum())
        for age in (2, 3, 4):
            pt = pos[s-1+age]
            u = pt-p0
            d = np.sqrt((u*u).sum(1))
            fast = np.flatnonzero(d > p/2)
            seen = set()
            if len(fast):
                tree = cKDTree(pt % box, boxsize=box)
                for i, js in zip(fast, tree.query_ball_point(pt[fast] % box, rc)):
                    js = np.asarray(js)
                    js = js[js != i]
                    if len(js):
                        r0 = np.sqrt((mic(p0[js]-p0[i])**2).sum(1))
                        seen.update((min(i, j), max(i, j)) for j in js[r0 >= rc+p])
            do = np.zeros(nb*T); do[:len(o)] = d[o]
            D = do.reshape(nb, T).max(1)
            keep = D[a_all]+D[b_all] > p
            c, h = blocks(pt[o])
            unc = int(near_pairs(c, h, a_all[keep], b_all[keep], rc).sum())
            rows.append(dict(window=w, build=int(s), age=age, crossings=len(seen), over=int(len(fast)),
                             max=round(float(d.max()), 4), blocks_over=int((D > p/2).sum()),
                             uncertified_pairs=unc, rebuild_pairs=rebuild_pairs))
            print(json.dumps(rows[-1]), flush=True)

summary = {}
for w in (0, 1):
    for age in (2, 3, 4):
        r = [x for x in rows if x["age"] == age and x["window"] == w]
        if not r:
            continue
        summary[f"window{w} age{age}"] = dict(
            builds=len(r), with_crossing=sum(x["crossings"] > 0 for x in r),
            crossings_mean=round(float(np.mean([x["crossings"] for x in r])), 2),
            over_mean=round(float(np.mean([x["over"] for x in r])), 1),
            uncertified_over_rebuild=round(float(np.mean([x["uncertified_pairs"]/x["rebuild_pairs"] for x in r])), 4))
steps = {w: int(z[f"flags{w}"].sum()) for w in (0, 1)}
print(json.dumps(dict(test=test, rc=rc, p=p, rebuilds_per_150_steps=steps, summary=summary), indent=1))

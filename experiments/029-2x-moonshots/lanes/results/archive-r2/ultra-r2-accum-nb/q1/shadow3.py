"""Q1 shadow crossing replay on the dump.py trajectories (q1/traj-<test>.npz): float32 positions, the Metal atom
order and the rebuild flag at every step of two 150-step windows.

A list flagged as rebuilt at step s was built from the positions before step s (pos[s-1]); at age k the force
evaluation sees pos[s-1+k]. For each build and ages 2-4 it counts:
  crossings: pairs with r(t0) >= rc+p and r(t) < rc (a sufficient condition for a pair the list could miss);
  over: atoms that moved more than p/2 since the build (the half-padding test fails when this is above zero);
  uncertified: block pairs with D_A+D_B > p whose current bounding boxes come within rc (the verifier's scan),
  against the block pairs whose boxes at the build come within rc+p (the builder's scan).
Blocks are 32 consecutive atoms in the Metal order of the build step.
Also (head, 18:05Z, from the web agent's Q1 answer): which mass class sets the largest displacement (water H at 1.008,
solute H at 1.5 after repartitioning, heavy), overall and per block over p/2; and for an append-only repair list with
a common t0, the tiles it would append: crossing pairs grouped by the lower block as x, one tile per 32 missing y atoms.
Masses come from q1/mass-<test>.npy (System order).
usage: shadow3.py <test> [padding fraction of the cutoff, default 0.08]"""
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
mass = np.load(q1/f"mass-{test}.npy")
cls = np.where(np.abs(mass-1.008) < 1e-3, 0, np.where(np.abs(mass-1.5) < 1e-3, 1, 2))
CLS = ["waterH", "soluteH", "heavy"]

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
            # Append repair: x is the lower block of the pair in the build's Metal order.
            rank = np.empty(len(o), np.int64); rank[o] = np.arange(len(o))
            missing = {}
            for i, j in seen:
                bi, bj = rank[i]//T, rank[j]//T
                x, y = (i, j) if bi <= bj else (j, i)
                missing.setdefault(min(bi, bj), set()).add(y)
            tiles = sum((len(v)+T-1)//T for v in missing.values())
            do = np.zeros(nb*T); do[:len(o)] = d[o]
            D = do.reshape(nb, T).max(1)
            arg = do.reshape(nb, T).argmax(1)
            oo = np.full(nb*T, -1); oo[:len(o)] = o
            setter = oo.reshape(nb, T)[np.arange(nb), arg]
            flagged = np.flatnonzero(D > p/2)
            by_cls = np.bincount(cls[setter[flagged]], minlength=3)
            over_cls = np.bincount(cls[fast], minlength=3)
            keep = D[a_all]+D[b_all] > p
            c, h = blocks(pt[o])
            unc = int(near_pairs(c, h, a_all[keep], b_all[keep], rc).sum())
            rows.append(dict(window=w, build=int(s), age=age, crossings=len(seen), over=int(len(fast)),
                             max=round(float(d.max()), 4), blocks_over=int((D > p/2).sum()),
                             uncertified_pairs=unc, rebuild_pairs=rebuild_pairs,
                             dmax_class=CLS[cls[int(d.argmax())]], blocks_over_by_class=by_cls.tolist(),
                             over_by_class=over_cls.tolist(), append_x_blocks=len(missing), append_tiles=tiles))
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
            uncertified_mean=round(float(np.mean([x["uncertified_pairs"] for x in r])), 1),
            uncertified_over_rebuild=round(float(np.mean([x["uncertified_pairs"]/x["rebuild_pairs"] for x in r])), 4),
            blocks_over_mean=round(float(np.mean([x["blocks_over"] for x in r])), 1),
            dmax_class={c: sum(x["dmax_class"] == c for x in r) for c in CLS},
            blocks_over_by_class=np.sum([x["blocks_over_by_class"] for x in r], 0).tolist(),
            append_tiles_mean=round(float(np.mean([x["append_tiles"] for x in r])), 2),
            append_tiles_max=max(x["append_tiles"] for x in r))
steps = {w: int(z[f"flags{w}"].sum()) for w in (0, 1)}
print(json.dumps(dict(test=test, rc=rc, p=p, rebuilds_per_150_steps=steps, summary=summary), indent=1))

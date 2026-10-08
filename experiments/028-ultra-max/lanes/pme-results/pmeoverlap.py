"""Does the PME chain overlap the neighbor-list build in a counters-mode record (one encoder per dispatch)?

usage: python pmeoverlap.py <counters .rec.gz>
Per step: list = findBlockBounds .. copyInteractionCounts, pme = findAtomGridIndex or gridSpreadCharge ..
gridInterpolateForce (any number of kernels between). Prints medians of the gaps and overlaps in us, and the
commit time of the buffer holding the PME chain relative to the GPU end of the list build.
"""
import gzip, statistics, sys

LIST_FIRST, LIST_LAST = "findBlockBounds", "copyInteractionCounts"
PME_FIRST, PME_LAST = ("findAtomGridIndex", "gridSpreadCharge"), "gridInterpolateForce"
steps, cur, state = [], None, None
buffers = []
for line in gzip.open(sys.argv[1], "rt"):
    f = line.split()
    if f[0] == "b":
        buffers.append((float(f[1])*1e9, float(f[2])*1e9, float(f[3])*1e9, f[4], f[5]))
        continue
    if f[0] != "e":
        continue
    name, t0, t1 = f[1], int(f[4]), int(f[5])
    if name == LIST_FIRST:
        cur, state = {"list": [], "pme": [], "after": []}, "list"
    if cur is None:
        continue
    if state == "list":
        cur["list"].append((name, t0, t1))
        if name == LIST_LAST:
            state = "gap"
    elif state == "gap" and name in PME_FIRST:
        state = "pme"
    if state == "pme":
        cur["pme"].append((name, t0, t1))
        if name == PME_LAST:
            state = "after"
            continue
    if state == "after":
        cur["after"].append((name, t0, t1))
        if name == "computeNonbonded":
            steps.append(cur)
            cur, state = None, None

def union(iv):
    total, covered = 0, None
    for s, e in sorted(iv):
        if covered is None or s > covered:
            total, covered = total+e-s, e
        elif e > covered:
            total, covered = total+e-covered, e
    return total

def overlap(a, b):
    return union(a)+union(b)-union(a+b)

rows = []
for s in steps:
    L = [(t0, t1) for _, t0, t1 in s["list"]]
    P = [(t0, t1) for _, t0, t1 in s["pme"]]
    A = [(t0, t1) for _, t0, t1 in s["after"]]
    fbwi = [t1 for n, _, t1 in s["list"] if n == "findBlocksWithInteractions"]
    rows.append(dict(
        pmeStartMinusListEnd=(min(t for t, _ in P)-max(t for _, t in L))*1e-3,
        pmeStartMinusFindBlocksEnd=(min(t for t, _ in P)-fbwi[-1])*1e-3 if fbwi else float("nan"),
        overlapListPme=overlap(L, P)*1e-3,
        listUnion=union(L)*1e-3, pmeUnion=union(P)*1e-3,
        overlapPmeAfter=overlap(P, A)*1e-3,
        afterUnion=union(A)*1e-3,
        pmeSum=sum(t1-t0 for t0, t1 in P)*1e-3))
print(f"{sys.argv[1]}: {len(rows)} steps with list build then PME chain")
for k in rows[0]:
    v = [r[k] for r in rows]
    print(f"  {k:28s} median {statistics.median(v):8.1f}  p10 {sorted(v)[len(v)//10]:8.1f}  p90 {sorted(v)[9*len(v)//10]:8.1f}")

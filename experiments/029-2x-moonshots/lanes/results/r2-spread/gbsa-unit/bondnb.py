"""How bonded and nonbonded share the concurrent force pass: for each step where both were sampled,
their starts, ends and overlap, and whether nonbonded runs longer when the overlap is larger.
usage: python bondnb.py <intervals.xml> <pid>
"""
import statistics
import sys
import xml.etree.ElementTree as ET

path, pid = sys.argv[1], sys.argv[2]
texts, spans = {}, []
for _, e in ET.iterparse(path, events=("end",)):
    if e.get("id") is not None:
        texts[e.get("id")] = e.text if e.tag in ("start-time", "duration") else (e.get("fmt") or e.text or "")
    if e.tag == "row":
        c = list(e)
        v = lambda x: texts.get(x.get("ref")) if x.get("ref") else (x.text if x.tag in ("start-time", "duration") else x.get("fmt") or x.text or "")
        if f"({pid})" in v(c[11]):
            spans.append((int(v(c[0])), int(v(c[1])), v(c[2]).rsplit(" (", 1)[0]))
        e.clear()
spans.sort()
bonded = [s for s in spans if s[2] == "computeBondedForces"]
nb = [s for s in spans if s[2] == "computeNonbonded"]
rows = []
j = 0
for t, d, _ in nb:
    while j < len(bonded) and bonded[j][0] < t-100e3:
        j += 1
    for bt, bd, _ in bonded[j:j+3]:
        if abs(bt-t) < 100e3:
            ov = max(0, min(t+d, bt+bd)-max(t, bt))
            rows.append(((bt-t)/1e3, bd/1e3, d/1e3, ov/1e3))
            break
print(f"pairs {len(rows)} of {len(nb)} nonbonded")
for name, k in (("bonded start - nb start", 0), ("bonded dur", 1), ("nb dur", 2), ("overlap", 3)):
    q = statistics.quantiles([r[k] for r in rows], n=4)
    print(f"  {name:24s} p25 {q[0]:6.1f} p50 {q[1]:6.1f} p75 {q[2]:6.1f}")
alone = [r[2] for r in nb and [(0, 0, s[1]/1e3, 0) for s in nb]]
rows.sort(key=lambda r: r[3])
n = len(rows)
for lo, hi in ((0, n//4), (n//4, n//2), (n//2, 3*n//4), (3*n//4, n)):
    part = rows[lo:hi]
    print(f"  overlap quartile p50 {statistics.median(r[3] for r in part):5.1f}: nb dur p50 {statistics.median(r[2] for r in part):5.1f}, bonded dur p50 {statistics.median(r[1] for r in part):5.1f}")
print(f"  all nonbonded dur p50 {statistics.median(s[1]/1e3 for s in nb):.1f}, unpaired p50 {statistics.median([s[1]/1e3 for s in nb if not any(abs(b[0]-s[0]) < 100e3 for b in bonded)] or [0]):.1f}")

"""Per-step spans of the gbsa kernel chain, from steps whose chain was sampled whole.
Segments are start to start, so each includes the kernel's unsampled tail and the dispatch gap after it.
usage: python chain.py <intervals.xml> <pid>
"""
import collections
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
# Each segment from the steps where both of its ends were sampled: start of A to the first start of B after it.
def first_after(i, name, limit):
    for t, d, n in spans[i+1:]:
        if t-spans[i][0] > limit:
            return None
        if n == name or (name == "integrate" and n.startswith("integrate")):
            return t
    return None
pairs = [("computeBornSumOwned", "computeGBSAForce1Owned", "BornSum"), ("computeGBSAForce1Owned", "reduceBornForceOwned", "Force1"),
         ("reduceBornForceOwned", "computeBondedForces", "reduce"), ("computeBondedForces", "integrate", "bonded+nonbonded"),
         ("integrate", "computeBornSumOwned", "integrator to next BornSum")]
for a, b, label in pairs:
    xs = []
    for i, (t, d, n) in enumerate(spans):
        if n == a or (a == "integrate" and n.startswith("integrate")):
            u = first_after(i, b, 250e3)
            if u is not None:
                xs.append((u-t)/1e3)
    q = statistics.quantiles(xs, n=4)
    print(f"{label:28s} n {len(xs):5d}  p25 {q[0]:6.1f}  p50 {q[1]:6.1f}  p75 {q[2]:6.1f}")

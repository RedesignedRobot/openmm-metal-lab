"""Idle gaps between consecutive kernels of one pid, summed per (previous kernel, next kernel) pair, us per step.
usage: python gaps.py <intervals.xml> <pid>
"""
import collections
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
nb = [s[0] for s in spans if s[2] == "computeNonbonded"]
first, last = nb[0], nb[-1]
nsteps = len(nb)-1
gaps, hist = collections.defaultdict(list), collections.Counter()
end, prevname = None, None
for t, d, n in spans:
    if not first <= t < last:
        continue
    if end is not None and t > end:
        gaps[(prevname, n)].append((t-end)/1e3)
    if end is None or t+d > end:
        end, prevname = t+d, n
total = sum(sum(g) for g in gaps.values())
print(f"steps {nsteps}  idle {total/nsteps:.1f} us/step")
for k, g in sorted(gaps.items(), key=lambda kv: -sum(kv[1]))[:25]:
    g.sort()
    print(f"{k[0][:30]:30s} -> {k[1][:30]:30s} {sum(g)/nsteps:7.2f} us/step  n/step {len(g)/nsteps:5.2f}  median {g[len(g)//2]:7.2f}")

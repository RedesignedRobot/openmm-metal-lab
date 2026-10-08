"""GPU busy union and gaps per step from a shader-timeline export: python busy.py <intervals.xml> <pid> [per-step kernel]"""
import sys, collections
import xml.etree.ElementTree as ET
path, pid = sys.argv[1], sys.argv[2]
per_step = sys.argv[3] if len(sys.argv) > 3 else "integrateLangevinMiddleFused"
texts, iv = {}, []
for _, e in ET.iterparse(path, events=("end",)):
    if e.get("id") is not None:
        texts[e.get("id")] = e.text if e.tag in ("start-time", "duration") else (e.get("fmt") or e.text or "")
    if e.tag == "row":
        c = list(e)
        v = lambda x: texts.get(x.get("ref")) if x.get("ref") else (x.text if x.tag in ("start-time", "duration") else x.get("fmt") or x.text or "")
        if f"({pid})" in v(c[11]):
            iv.append((int(v(c[0])), int(v(c[1])), v(c[2]).rsplit(" (", 1)[0]))
        e.clear()
iv.sort()
steps = [s for s, d, n in iv if n == per_step]
# use the middle 80% of steps
lo, hi = steps[len(steps)//10], steps[-len(steps)//10]
n = sum(1 for s in steps if lo <= s < hi)
busy, end = 0, lo
gaps = collections.Counter()
prev = None
for s, d, name in iv:
    if s < lo or s >= hi: continue
    if s > end:
        gaps[(prev, name)] += s-end
    busy += max(0, s+d-max(s, end))
    if s+d > end:
        end, prev = s+d, name
span = hi-lo
print(f"steps {n}  span/step {span/n/1e3:.1f} us  busy/step {busy/n/1e3:.1f} us  idle/step {(span-busy)/n/1e3:.1f} us")
for (a, b), g in gaps.most_common(12):
    print(f"  gap {g/n/1e3:6.2f} us/step  after {a} before {b}")

"""When two shaders run relative to each other, per step, from a shader-timeline export (metal-shader-profiler-intervals).

usage: python overlap.py <intervals.xml> <python pid> [<first shader> <second shader>]
Rows are one interval per shader per kick: start and sample duration (the span the shader timeline sampled it over).
For each interval of the first shader (default computeBondedForces), the next interval of the second (default
computeNonbonded) in the same process is paired with it. Overlap is first end minus second start, when positive.
"""
import statistics
import sys
import xml.etree.ElementTree as ET

path, pid = sys.argv[1], sys.argv[2]
first, second = (sys.argv[3], sys.argv[4]) if len(sys.argv) > 4 else ("computeBondedForces", "computeNonbonded")
texts, rows = {}, []
for _, e in ET.iterparse(path, events=("end",)):
    if e.get("id") is not None:
        texts[e.get("id")] = e.text if e.tag in ("start-time", "duration", "pid") else (e.get("fmt") or e.text or "")
    if e.tag == "row":
        c = list(e)
        v = lambda x: texts.get(x.get("ref")) if x.get("ref") else (x.text if x.tag in ("start-time", "duration") else x.get("fmt") or x.text or "")
        if f"({pid})" in v(c[11]):
            start = int(v(c[0]))/1e3
            rows.append((start, start+int(v(c[1]))/1e3, v(c[2]).rsplit(" (", 1)[0]))
        e.clear()
rows.sort()
pairs = []
for i, (s, e, name) in enumerate(rows):
    if name != first:
        continue
    nxt = next((r for r in rows[i+1:] if r[2] in (first, second)), None)
    if nxt and nxt[2] == second:
        pairs.append((s, e, nxt[0], nxt[1]))
print(f"{len(rows)} intervals in pid {pid}, {len(pairs)} {first} -> {second} pairs")
if not pairs:
    sys.exit(0)
ov = [max(0.0, e1-s2) for s1, e1, s2, e2 in pairs]
gap = [s2-e1 for s1, e1, s2, e2 in pairs]
med = lambda xs: statistics.median(xs)
print(f"{first}: median span {med([e1-s1 for s1, e1, s2, e2 in pairs]):.1f} us; {second}: median span {med([e2-s2 for s1, e1, s2, e2 in pairs]):.1f} us")
print(f"{second} start minus {first} end: median {med(gap):.2f} us, min {min(gap):.2f}, max {max(gap):.2f}")
print(f"overlapping pairs: {sum(o > 0 for o in ov)} of {len(ov)}, overlap median over those "
      f"{med([o for o in ov if o > 0]) if any(ov) else 0:.1f} us, mean over all {statistics.mean(ov):.2f} us")

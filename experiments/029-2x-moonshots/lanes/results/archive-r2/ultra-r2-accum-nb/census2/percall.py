"""Per-call durations of one kernel from a shader-timeline export: percall.py <intervals.xml> <pid> <kernel>"""
import sys
import xml.etree.ElementTree as ET
path, pid, name = sys.argv[1:4]
texts, d = {}, []
for _, e in ET.iterparse(path, events=("end",)):
    if e.get("id") is not None:
        texts[e.get("id")] = e.text if e.tag in ("start-time", "duration") else (e.get("fmt") or e.text or "")
    if e.tag == "row":
        c = list(e)
        v = lambda x: texts.get(x.get("ref")) if x.get("ref") else (x.text if x.tag in ("start-time", "duration") else x.get("fmt") or x.text or "")
        if f"({pid})" in v(c[11]) and v(c[2]).rsplit(" (", 1)[0] == name:
            d.append(int(v(c[1]))/1000)
        e.clear()
d.sort()
n = len(d)
q = lambda f: d[min(n-1, int(f*n))]
print(f"{name}: {n} calls, us: min {d[0]:.1f} p10 {q(.1):.1f} p33 {q(.33):.1f} p50 {q(.5):.1f} p67 {q(.67):.1f} p90 {q(.9):.1f} max {d[-1]:.1f}")
print("over 20 us:", sum(x > 20 for x in d), "mean of those:", round(sum(x for x in d if x > 20)/max(1, sum(x > 20 for x in d)), 1))

"""Per-dispatch duration histogram of one kernel from a shader-timeline export (rebuild cadence of findBlocks)."""
import sys, xml.etree.ElementTree as ET
path, pid, kern = sys.argv[1], sys.argv[2], sys.argv[3]
texts, d = {}, []
for _, e in ET.iterparse(path, events=("end",)):
    if e.get("id") is not None:
        texts[e.get("id")] = e.text if e.tag in ("start-time", "duration") else (e.get("fmt") or e.text or "")
    if e.tag == "row":
        c = list(e)
        v = lambda x: texts.get(x.get("ref")) if x.get("ref") else (x.text if x.tag in ("start-time", "duration") else x.get("fmt") or x.text or "")
        if f"({pid})" in v(c[11]) and v(c[2]).rsplit(" (", 1)[0] == kern:
            d.append(int(v(c[1]))/1e3)
        e.clear()
d.sort()
n = len(d)
print(kern, "rows", n, "total us", round(sum(d)))
for lo, hi in [(0, 10), (10, 50), (50, 200), (200, 500), (500, 1e9)]:
    s = [x for x in d if lo <= x < hi]
    print(f"  {lo}-{hi} us: {len(s)} rows, {sum(s):.0f} us, median {s[len(s)//2] if s else 0:.1f}")

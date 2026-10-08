"""Per-kernel GPU time per step from two shader-timeline exports, side by side (for example Metal against OpenCL).

usage: python kernsum.py <a-intervals.xml> <a pid> <b-intervals.xml> <b pid> [<per-step kernel>]
Each metal-shader-profiler-intervals row is one shader's sampled span in one kick. Rows of the traced pid are summed
by shader name (the pipeline id in parentheses and OpenCL's __entry_ prefix dropped) and divided by the count of the per-step kernel
(computeNonbonded by default, once per step on rf), so warm-up and minimization steps count like the rest.
"""
import collections
import sys
import xml.etree.ElementTree as ET

OPENCL_PREFIX = "__entry_"  # Apple's OpenCL names each kernel's Metal function __entry_<kernel>


def load(path, pid):
    texts, total, count = {}, collections.defaultdict(float), collections.Counter()
    for _, e in ET.iterparse(path, events=("end",)):
        if e.get("id") is not None:
            texts[e.get("id")] = e.text if e.tag in ("start-time", "duration") else (e.get("fmt") or e.text or "")
        if e.tag == "row":
            c = list(e)
            v = lambda x: texts.get(x.get("ref")) if x.get("ref") else (x.text if x.tag in ("start-time", "duration") else x.get("fmt") or x.text or "")
            if f"({pid})" in v(c[11]):
                name = v(c[2]).rsplit(" (", 1)[0].removeprefix(OPENCL_PREFIX)
                total[name] += int(v(c[1]))/1e3
                count[name] += 1
            e.clear()
    return total, count


per_step = sys.argv[5] if len(sys.argv) > 5 else "computeNonbonded"
(ta, ca), (tb, cb) = load(sys.argv[1], sys.argv[2]), load(sys.argv[3], sys.argv[4])
sa, sb = ca[per_step], cb[per_step]
print(f"steps by {per_step}: a {sa}, b {sb}")
rows = [(name, ta[name]/sa, tb[name]/sb, ca[name]/sa, cb[name]/sb) for name in set(ta) | set(tb)]
rows.sort(key=lambda r: -abs(r[1]-r[2]))
print(f"{'kernel':44s} {'a us/step':>10s} {'b us/step':>10s} {'a-b':>8s} {'a/step':>7s} {'b/step':>7s}")
for name, a, b, na, nb in rows:
    print(f"{name[:44]:44s} {a:10.2f} {b:10.2f} {a-b:8.2f} {na:7.2f} {nb:7.2f}")
print(f"{'total':44s} {sum(r[1] for r in rows):10.2f} {sum(r[2] for r in rows):10.2f} {sum(r[1]-r[2] for r in rows):8.2f}")

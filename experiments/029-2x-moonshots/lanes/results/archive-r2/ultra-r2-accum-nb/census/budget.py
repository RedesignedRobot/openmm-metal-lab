"""One-trace per-step GPU budget from a shader-timeline export (metal-shader-profiler-intervals XML).

usage: budget.py <intervals.xml> <pid> [skip steps, default 20]
Steps are counted by computeNonbonded (once per step on rf). The window runs from the start of the skip-th
computeNonbonded to the start of the last one, so warm-up is dropped. Inside it, each kernel's time is split into
pair (computeNonbonded), list (findBlockBounds through copyInteractionCounts) and other. Busy is the union of all
intervals, so kernels that overlap count once; idle is the window minus busy and minus gaps over 1 ms (host pauses between phases), which are reported apart. Categories are summed durations and
can exceed busy when kernels overlap.
"""
import collections
import sys
import xml.etree.ElementTree as ET

LIST = {"findBlockBounds", "prepareRebuildDispatch", "countBlockBins", "sumBlockBins", "scatterBlocks", "sortBoxData",
        "findBlocksWithInteractions", "copyInteractionCounts", "computeSortKeys"}
path, pid = sys.argv[1], sys.argv[2]
skip = int(sys.argv[3]) if len(sys.argv) > 3 else 20
texts, rows = {}, []
for _, e in ET.iterparse(path, events=("end",)):
    if e.get("id") is not None:
        texts[e.get("id")] = e.text if e.tag in ("start-time", "duration") else (e.get("fmt") or e.text or "")
    if e.tag == "row":
        c = list(e)
        v = lambda x: texts.get(x.get("ref")) if x.get("ref") else (x.text if x.tag in ("start-time", "duration") else x.get("fmt") or x.text or "")
        if f"({pid})" in v(c[11]):
            rows.append((int(v(c[0])), int(v(c[1])), v(c[2]).rsplit(" (", 1)[0]))
        e.clear()
rows.sort()
nb = [s for s, d, n in rows if n == "computeNonbonded"]
t0, t1 = nb[skip], nb[-1]
steps = len(nb)-1-skip
cat, kern, count = collections.defaultdict(float), collections.defaultdict(float), collections.Counter()
busy, end, pause = 0, t0, 0
for s, d, n in rows:
    if s < t0 or s >= t1:
        continue
    kind = "pair" if n == "computeNonbonded" else ("list" if n in LIST else "other")
    cat[kind] += d
    kern[n] += d
    count[n] += 1
    e = min(s+d, t1)
    if s-end > 1e6:
        pause += s-end
    if e > end:
        busy += e-max(s, end)
        end = e
wall = t1-t0
print(f"{path}: {steps} steps, {wall/steps/1e3:.1f} us/step of trace wall")
for k in ("pair", "list", "other"):
    print(f"  {k:6s} {cat[k]/steps/1e3:8.1f} us/step (summed durations)")
print(f"  busy   {busy/steps/1e3:8.1f} us/step (union)")
print(f"  idle   {(wall-busy-pause)/steps/1e3:8.1f} us/step, plus {pause/1e6:.1f} ms in gaps over 1 ms")
print("  list kernels: " + ", ".join(f"{n} {kern[n]/steps/1e3:.1f} ({count[n]/steps:.2f}/step)" for n in sorted(LIST) if count[n]))
print("  other kernels: " + ", ".join(f"{n} {kern[n]/steps/1e3:.1f}" for n in sorted(kern, key=lambda n: -kern[n]) if n not in LIST and n != "computeNonbonded"))

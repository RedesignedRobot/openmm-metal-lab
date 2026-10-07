"""Median per-step timeline from a shader-timeline export: python chain.py <intervals.xml> <pid> [per-step kernel]
For each kernel: median start and end offset (us) from the step's first sampled span, and median sampled span."""
import sys, collections, statistics
import xml.etree.ElementTree as ET
path, pid = sys.argv[1], sys.argv[2]
anchor = sys.argv[3] if len(sys.argv) > 3 else "clearFourBuffers"
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
starts = [s for s, d, n in iv if n == anchor]
lo, hi = len(starts)//10, len(starts) - len(starts)//10
st, en, du, cnt = collections.defaultdict(list), collections.defaultdict(list), collections.defaultdict(list), collections.Counter()
lengths = []
born_phases = []
j = 0
for k in range(lo, hi-1):
    a, b = starts[k], starts[k+1]
    lengths.append((b-a)/1e3)
    while j < len(iv) and iv[j][0] < a: j += 1
    i = j
    seen = collections.defaultdict(lambda: [None, None, 0])
    while i < len(iv) and iv[i][0] < b:
        s, d, n = iv[i]
        r = seen[n]
        r[0] = s if r[0] is None else min(r[0], s)
        r[1] = s+d if r[1] is None else max(r[1], s+d)
        r[2] += d
        i += 1
    born = seen.get("computeBornSumRowOwned", seen.get("computeBornSumOwned"))
    force = seen.get("computeGBSAForce1Owned")
    if born is not None and force is not None:
        born_phases.append((force[0]-born[0])/1e3)
    for n, (s, e_, d) in seen.items():
        st[n].append((s-a)/1e3); en[n].append((e_-a)/1e3); du[n].append(d/1e3); cnt[n] += 1
n_steps = hi-1-lo
print(f"steps {n_steps}  median step {statistics.median(lengths):.1f} us  (anchor {anchor})")
print(f"{'kernel':34s} {'frac':>5s} {'start':>7s} {'end':>7s} {'sampled':>8s}")
for n in sorted(st, key=lambda n: statistics.median(st[n])):
    print(f"{n:34s} {cnt[n]/n_steps:5.2f} {statistics.median(st[n]):7.1f} {statistics.median(en[n]):7.1f} {statistics.median(du[n]):8.1f}")

if born_phases:
    print(f"whole Born phase: median {statistics.median(born_phases):.3f} us, samples {len(born_phases)}")

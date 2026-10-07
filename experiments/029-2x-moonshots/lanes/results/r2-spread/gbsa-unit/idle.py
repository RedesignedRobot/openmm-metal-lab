"""Encoder-level idle for one pid: python idle.py <gpu intervals.xml> <shader intervals.xml> <submissions.xml> <pid> <anchor kernel>
GPU intervals give when any work of the pid runs; the gaps between them are idle. Steps are counted by the anchor
kernel in the shader timeline. Each gap is attributed to the kernels on either side and to the submission track."""
import sys, bisect, collections, statistics
import xml.etree.ElementTree as ET

def rows(path):
    texts, out = {}, []
    for _, e in ET.iterparse(path, events=("end",)):
        if e.get("id") is not None:
            texts[e.get("id")] = e.text if e.tag in ("start-time", "duration") else (e.get("fmt") or e.text or "")
        if e.tag == "row":
            v = lambda x: texts.get(x.get("ref")) if x.get("ref") else (x.text if x.tag in ("start-time", "duration") else x.get("fmt") or x.text or "")
            out.append([v(x) for x in e]); e.clear()
    return out

gp, sp, subp, pid, anchor = sys.argv[1:6]
tag = f"({pid})"
G = sorted((int(r[0]), int(r[1])) for r in rows(gp) if tag in " ".join(str(x) for x in r))
S = sorted((int(r[0]), int(r[1]), r[2].rsplit(" (", 1)[0]) for r in rows(sp) if tag in str(r[11]))
U = sorted(int(r[0]) for r in rows(subp) if tag in " ".join(str(x) for x in r))
# merge GPU intervals
M = []
for s, d in G:
    e = s + d
    if M and s <= M[-1][1]:
        M[-1][1] = max(M[-1][1], e)
    else:
        M.append([s, e])
anchors = [s for s, d, n in S if n == anchor]
# middle 80% of steps
a0, a1 = anchors[len(anchors)//10], anchors[len(anchors)*9//10]
steps = len([a for a in anchors if a0 <= a < a1])
busy = sum(min(e, a1) - max(s, a0) for s, e in M if e > a0 and s < a1)
wall = a1 - a0
print(f"steps {steps}  wall/step {wall/steps/1e3:.1f} us  GPU-interval busy/step {busy/steps/1e3:.1f}  idle/step {(wall-busy)/steps/1e3:.1f}")
print(f"GPU intervals {len(G)}, merged {len(M)}, per step {len([1 for s,e in M if a0<=s<a1])/steps:.3f}; submissions per step {len([u for u in U if a0<=u<a1])/steps:.3f}")
# gaps between merged intervals, labeled by the last sampled kernel before and first after, and by the latest submission
starts = [x[0] for x in S]
gaps = collections.defaultdict(list)
since = []
for (s0, e0), (s1, e1) in zip(M, M[1:]):
    if not (a0 <= e0 < a1): continue
    gap = (s1 - e0) / 1e3
    i = bisect.bisect_right(starts, e0) - 1
    j = bisect.bisect_left(starts, s1)
    before = S[i][2] if i >= 0 else "?"
    after = S[j][2] if j < len(S) and S[j][0] - s1 < 50e3 else "?"
    gaps[(before, after)].append(gap)
    k = bisect.bisect_right(U, s1) - 1
    since.append(((s1 - U[k]) / 1e3 if k >= 0 else float("nan"), (s1 - e0) / 1e3, (U[k] - e0) / 1e3 if k >= 0 else float("nan")))
for k, v in sorted(gaps.items(), key=lambda kv: -sum(kv[1])):
    print(f"  gap {k[0][:28]:28s} -> {k[1][:28]:28s} n {len(v):5d}  sum/step {sum(v)/steps:6.2f} us  median {statistics.median(v):7.2f}  p90 {sorted(v)[len(v)*9//10]:7.2f}")
if since:
    print("next interval start minus latest submission: median %.1f us; gap median %.1f; latest submission minus previous interval end: median %.1f" %
          tuple(statistics.median(x[i] for x in since) for i in range(3)))
# inside intervals: the time between sampled kernels (unsampled tails or dispatch boundaries)

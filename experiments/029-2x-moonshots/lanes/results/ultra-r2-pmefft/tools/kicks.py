"""GPU kicks (metal-gpu-intervals) of one pid: per kick label start/duration, the gaps between kicks, and which
shader kernels open and close each kick.
usage: python kicks.py <gpu.xml> <shader-intervals.xml> <pid>
"""
import bisect
import collections
import sys
import xml.etree.ElementTree as ET


def rows(path):
    texts = {}
    for _, e in ET.iterparse(path, events=("end",)):
        if e.get("id") is not None:
            texts[e.get("id")] = e
        if e.tag == "row":
            out = []
            for x in e:
                x = texts[x.get("ref")] if x.get("ref") else x
                out.append(x)
            yield out


def val(x):
    return x.text if x.tag in ("start-time", "duration", "uint64", "metal-command-buffer-id") else (x.get("fmt") or x.text or "")


gpu_path, sh_path, pid = sys.argv[1], sys.argv[2], sys.argv[3]
kicks = []
for c in rows(gpu_path):
    if f"({pid})" not in val(c[10]):
        continue
    label = val(c[6]).split("   (")[0]
    kicks.append((int(val(c[0])), int(val(c[1])), val(c[2]), label, int(val(c[15])), int(val(c[16]))))
kicks.sort()
spans = []
for c in rows(sh_path):
    if f"({pid})" in val(c[11]):
        spans.append((int(val(c[0])), int(val(c[1])), val(c[2]).rsplit(" (", 1)[0]))
spans.sort()
starts = [s[0] for s in spans]
nb = [s[0] for s in spans if s[2] == "computeNonbonded"]
first, last = nb[len(nb)//10], nb[-1]
nsteps = sum(1 for t in nb if first <= t < last)
sel = [k for k in kicks if first <= k[0] < last]
print(f"steps {nsteps}  kicks/step {len(sel)/nsteps:.2f}  channels {collections.Counter(k[2] for k in sel)}")
busy = sum(k[1] for k in sel)/1e3/nsteps
print(f"kick busy {busy:.1f} us/step  wall {(last-first)/1e3/nsteps:.1f}")


def kernels_in(k):
    i, j = bisect.bisect_left(starts, k[0]), bisect.bisect_right(starts, k[0]+k[1])
    names = [spans[x][2] for x in range(i, j)]
    return (names[0], names[-1]) if names else ("-", "-")


gaps = collections.defaultdict(list)
durs = collections.defaultdict(list)
for a, b in zip(sel, sel[1:]):
    ka, kb = kernels_in(a), kernels_in(b)
    gaps[(ka[1], kb[0])].append((b[0]-(a[0]+a[1]))/1e3)
for k in sel:
    durs[kernels_in(k)].append(k[1]/1e3)
print("kick gaps (last kernel of kick -> first kernel of next kick), us/step, n/step, median:")
for key, g in sorted(gaps.items(), key=lambda kv: -sum(kv[1]))[:12]:
    g.sort()
    print(f"  {key[0][:28]:28s} -> {key[1][:28]:28s} {sum(g)/nsteps:7.2f} {len(g)/nsteps:5.2f} {g[len(g)//2]:7.2f}")
print("kicks by (first, last kernel): us/step, n/step, median dur:")
for key, d in sorted(durs.items(), key=lambda kv: -sum(kv[1]))[:12]:
    d.sort()
    print(f"  {key[0][:28]:28s} .. {key[1][:28]:28s} {sum(d)/nsteps:7.2f} {len(d)/nsteps:5.2f} {d[len(d)//2]:7.2f}")
print("sample labels:", collections.Counter(k[3].split(":")[1] if ":" in k[3] else k[3] for k in sel).most_common(6))
head, tail = [], []
for k in sel:
    i, j = bisect.bisect_left(starts, k[0]), bisect.bisect_right(starts, k[0]+k[1])
    if j > i:
        head.append((spans[i][0]-k[0])/1e3)
        tail.append((k[0]+k[1]-max(s[0]+s[1] for s in spans[i:j]))/1e3)
head.sort(); tail.sort()
print(f"kick head (kick start to first shader) median {head[len(head)//2]:.2f} mean {sum(head)/len(head):.2f}; "
      f"tail (last shader end to kick end) median {tail[len(tail)//2]:.2f} mean {sum(tail)/len(tail):.2f}")
lastk = collections.Counter()
for k in sel:
    i, j = bisect.bisect_left(starts, k[0]), bisect.bisect_right(starts, k[0]+k[1])
    if j > i:
        lastk[max(spans[i:j], key=lambda s: s[0]+s[1])[2]] += 1
print("last-ending kernel per kick:", lastk.most_common(4))
bylast = collections.defaultdict(list)
for k in kicks:
    i, j = bisect.bisect_left(starts, k[0]), bisect.bisect_right(starts, k[0]+k[1])
    if j > i:
        s = max(spans[i:j], key=lambda s: s[0]+s[1])
        bylast[s[2]].append((k[0]+k[1]-(s[0]+s[1]))/1e3)
for n, t in sorted(bylast.items(), key=lambda kv: -len(kv[1]))[:8]:
    t.sort()
    print(f"  tail after {n[:30]:30s} n {len(t):6d} median {t[len(t)//2]:7.2f} p10 {t[len(t)//10]:7.2f} p90 {t[9*len(t)//10]:7.2f}")

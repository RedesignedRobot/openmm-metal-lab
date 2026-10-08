"""ns/day per configuration of an ab.sh outdir: median over rounds, round spread, ratio to a base per precision,
us/step, and the background VM CPU range from loads.txt.  usage: absum.py <outdir> <single base> [mixed base]"""
import json, glob, os, re, statistics, sys
out, bases = sys.argv[1], sys.argv[2:]
labels = [l.split()[0] for l in open(os.path.join(out, "configs.txt"))]
prec = {l.split()[0]: l.split()[2] for l in open(os.path.join(out, "configs.txt"))}
med, runs = {}, {}
for c in labels:
    vals = []
    for f in sorted(glob.glob(os.path.join(out, f"{c}-*-round*.json"))):
        b = json.load(open(f))["benchmarks"]
        vals += [x["ns_per_day"] for x in b]
    runs[c] = vals
    med[c] = statistics.median(vals) if vals else float("nan")
base = {prec[b]: b for b in bases}
for c in labels:
    v, b = runs[c], base.get(prec[c])
    if not v:
        print(f"{c:8s} {prec[c]:6s} no result")
        continue
    us = 4e-6/(med[c]/86400)*1e6  # 4 fs step
    ratio = med[c]/med[b] if b else float("nan")
    print(f"{c:8s} {prec[c]:6s} {med[c]:8.1f} ns/day {us:6.1f} us/step  x{ratio:.3f} ({us-4e-6/(med[b]/86400)*1e6:+.1f} us)  spread {100*(max(v)-min(v))/min(v):.2f}%  n={len(v)}")
vm = [int(x) for x in re.findall(r" vm (\d+)%", open(os.path.join(out, "loads.txt")).read())]
print(f"Background VM CPU {min(vm)}-{max(vm)}%")

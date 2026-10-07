# Summarize ft.sh output: median of per-run medians, ratio base/variant (>1 means variant faster).
import sys, re, statistics, collections
res = collections.defaultdict(list); v = None
for l in open(sys.argv[1]):
    m = re.match(r'round=\d+ variant=(\S+)', l)
    if m: v = m.group(1); continue
    m = re.match(r'(\S+) (\S+) ms/eval median (\S+)', l)
    if m and v: res[(m.group(1), v)].append(float(m.group(3)))
ref = sys.argv[2]
for t in sorted({k[0] for k in res}):
    b = statistics.median(res[(t, ref)])
    print(t.ljust(10), '  '.join(f"{v} {statistics.median(x):.4f}ms (x{b/statistics.median(x):.3f})" for (tt, v), x in sorted(res.items()) if tt == t))

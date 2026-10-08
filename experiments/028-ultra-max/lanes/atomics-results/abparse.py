# Summarize an ab.sh log: median ns/day per (test, variant) and ratio to the first variant listed.
import re, sys, statistics, collections
lines = open(sys.argv[1]).read().splitlines()
ref = sys.argv[2]
res = collections.defaultdict(list)
cur = None
for l in lines:
    m = re.match(r'round=\d+ test=(\S+) variant=(\S+)', l)
    if m:
        cur = (m.group(1), m.group(2)); continue
    if cur and l.strip() and not l.startswith('FAILED') and l != 'DONE':
        try:
            res[cur].append(float(l.split()[-1]))
        except ValueError:
            pass
tests = sorted({k[0] for k in res})
variants = sorted({k[1] for k in res})
for t in tests:
    base = statistics.median(res[(t, ref)]) if res[(t, ref)] else None
    row = []
    for v in variants:
        if res[(t, v)]:
            med = statistics.median(res[(t, v)])
            row.append(f"{v} {med:.1f} ({med/base:.3f})" if base else f"{v} {med:.1f}")
    print(f"{t:12s} " + "  ".join(row) + "   runs=" + str({v: len(res[(t,v)]) for v in variants}))

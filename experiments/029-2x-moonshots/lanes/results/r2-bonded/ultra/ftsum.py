import sys, json, collections, statistics
d = collections.defaultdict(list)
for l in open(sys.argv[1]):
    r = json.loads(l)
    if 'us' in r:
        d[(r['test'], r.get('prec', 'single'), r['arm'])].append(r['us'])
    else:
        d[(r['test'], r.get('prec', 'single'), r['arm'])].append(float('nan'))
base = sys.argv[2] if len(sys.argv) > 2 else 'base'
for (t, p, a), v in sorted(d.items()):
    m = statistics.median(v)
    b = d.get((t, p, base))
    rb = statistics.median(b) if b else float('nan')
    print(f'{t:18s} {p:6s} {a:10s} us/eval {m:9.1f}  ({" ".join("%.1f" % x for x in v)})  base-arm {rb-m:+8.1f} us  ratio {rb/m:.3f}')

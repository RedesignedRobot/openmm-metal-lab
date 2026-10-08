# Per section of an NB_TIME file: median GPU time of each phase, split into rebuild and early-exit steps.
import sys, statistics
threshold = float(sys.argv[2]) if len(sys.argv) > 2 else 100.0
wanted = sys.argv[3].split(',') if len(sys.argv) > 3 else None
sections, cur, step = {}, None, None
for line in open(sys.argv[1]):
    if line.startswith('== '):
        cur = sections.setdefault(line[3:].strip(), [])
        step = None
        continue
    label, us = line.split()
    if label == 'bounds':
        step = {}
        cur.append(step)
    if step is not None:
        step[label] = float(us)
for name, steps in sections.items():
    if wanted and name.split()[1] not in wanted:
        continue
    steps = [s for s in steps[50:] if 'find' in s]
    for kind, sel in (('rebuild', lambda s: s['find'] > threshold), ('exit', lambda s: s['find'] <= threshold)):
        group = [s for s in steps if sel(s)]
        labels = sorted({k for s in group for k in s}, key=lambda k: ['bounds', 'sort', 'boxdata', 'find', 'nonbonded'].index(k) if k in ('bounds', 'sort', 'boxdata', 'find', 'nonbonded') else 9)
        cells = ' '.join(f"{k} {statistics.median([s[k] for s in group if k in s]):6.1f}" for k in labels)
        print(f"{name:20s} {kind:7s} n {len(group):4d} {cells}")

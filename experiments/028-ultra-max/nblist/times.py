# Summarize an NB_TIME file: per label, count, mean and median GPU us; for "find", split the
# rebuild dispatches (over 3x the minimum) from the early exits.
import sys, statistics
sections = {}
times = None
for line in open(sys.argv[1]):
    if line.startswith('== '):
        times = sections.setdefault(line[3:].strip(), {})
        continue
    label, us = line.split()
    times.setdefault(label, []).append(float(us))
skip = int(sys.argv[2]) if len(sys.argv) > 2 else 50
for name, times in sections.items():
  print('==', name)
  steps = len(times.get('find', [0]))-skip
  for label, values in times.items():
    values = values[skip:]
    if not values:
        continue
    line = f'  {label:10s} n={len(values):6d} per-step={sum(values)/max(steps,1):8.1f} median={statistics.median(values):8.1f}'
    if label == 'find':
        low = min(values)
        rebuilds = [v for v in values if v > 3*low]
        if rebuilds:
            line += f'  rebuilds {len(rebuilds)/len(values):.2f}, median {statistics.median(rebuilds):.1f}, exits {statistics.median([v for v in values if v <= 3*low]):.1f}'
    print(line)

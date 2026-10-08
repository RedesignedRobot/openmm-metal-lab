"""Per-run overhead of cold ab.sh runs on the M3 Ultra: wall time between consecutive run starts in loads.txt
minus the timed elapsed_time in that run's JSON. Read-only over every lane's outdirs."""
import glob
import json
import os
import re
import statistics
from datetime import datetime

LINE = re.compile(r'^(\S+Z) round (\d+) (\S+) (\S+) load \{')
by_key = {}
screens = 0
for loads in glob.glob('/tmp/openmm-metal-bench/ultra-*/**/loads.txt', recursive=True):
    outdir = os.path.dirname(loads)
    if not os.path.exists(os.path.join(outdir, 'configs.txt')):
        continue
    starts = []
    for line in open(loads):
        m = LINE.match(line)
        if m:
            starts.append((datetime.strptime(m.group(1), '%Y-%m-%dT%H:%M:%SZ'), m.group(2), m.group(3), m.group(4)))
    if len(starts) < 2:
        continue
    screens += 1
    for (t0, r, test, label), (t1, *_rest) in zip(starts, starts[1:]):
        path = os.path.join(outdir, f'{label}-{test}-round{r}.json')
        if not os.path.exists(path):
            continue
        try:
            result = json.load(open(path))['benchmarks'][0]
        except (ValueError, IndexError, KeyError):
            continue
        if 'elapsed_time' not in result:
            continue
        wall = (t1 - t0).total_seconds()
        overhead = wall - result['elapsed_time']
        if overhead < 0 or overhead > 300:
            continue
        key = (test, result['platform'], result['precision'])
        by_key.setdefault(key, []).append(overhead)
print(f'{screens} screens')
print(f'{"test":18} {"platform":8} {"precision":9} {"runs":>5} {"median":>7} {"p25":>6} {"p75":>6}   seconds of wall per run beyond the timed call')
for key in sorted(by_key):
    values = sorted(by_key[key])
    if len(values) < 3:
        continue
    q = statistics.quantiles(values, n=4)
    print(f'{key[0]:18} {key[1]:8} {key[2]:9} {len(values):5d} {statistics.median(values):7.1f} {q[0]:6.1f} {q[2]:6.1f}')

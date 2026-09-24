"""Medians over rounds of workloads.py JSON lines. usage: wlsum.py <file.jsonl>"""
import json
import statistics
import sys
from collections import defaultdict

rows = [json.loads(line) for line in open(sys.argv[1]) if line.startswith('{')]
groups = defaultdict(list)
for row in rows:
    if row['item'] == 'sync':
        groups[(row['mode'], row['platform'])].append(row['us_per_step'])
    elif row['item'] == 'ctx':
        for key in ('first_create_s', 'first_first_step_s', 'first_total_s', 'second_total_s'):
            groups[(row['test'], row['variant'], key, row['platform'])].append(row[key])
    elif row['item'] == 'min':
        groups[(row['max_iterations'], row['platform'] + '-' + row['precision'])].append(
            (row['seconds'], row['pe_after'], row['rms_force_after']))
for key in sorted(groups, key=str):
    values = groups[key]
    if isinstance(values[0], tuple):
        seconds = [v[0] for v in values]
        print(key, f"median {statistics.median(seconds):.2f} s  runs {' '.join(f'{s:.2f}' for s in seconds)}  "
              f"pe_after {' '.join(f'{v[1]:.0f}' for v in values)}  rmsF {' '.join(f'{v[2]:.1f}' for v in values)}")
    else:
        print(key, f"median {statistics.median(values):.4g}  runs {' '.join(f'{v:.4g}' for v in values)}")

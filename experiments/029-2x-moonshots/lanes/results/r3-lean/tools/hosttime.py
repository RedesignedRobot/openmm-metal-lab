import json
import statistics
import sys
from collections import defaultdict
from pathlib import Path
runs = defaultdict(list)
for file in Path(sys.argv[1]).glob('*.json'):
    label = file.name.split('-round')[0]
    for row in json.loads(file.read_text()).get('benchmarks', []):
        test = row['test']
        arm = label[:-(len(test)+1)]
        # dt(fs) / rate(ns/day) converted to microseconds per step.
        runs[test, arm].append(row['timestep_in_fs']*86400/row['ns_per_day'])
print('host clock, median us/step; positive saved_us means faster')
print('test precision base_us mine_us saved_us speedup')
for test in sorted({k[0] for k in runs}):
    for prec in ['single', 'mixed']:
        base = statistics.median(runs[test, 'base-'+prec])
        mine = statistics.median(runs[test, 'mine-'+prec])
        print(test, prec, f'{base:.3f} {mine:.3f} {base-mine:.3f} {base/mine:.5f}')

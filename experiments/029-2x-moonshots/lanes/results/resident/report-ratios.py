"""Render measured ab.sh ratios; require every requested test and round."""
import argparse
import json
import re
import statistics
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('outdirs', nargs='+', type=Path)
p.add_argument('--candidate', required=True)
p.add_argument('--rounds', required=True, type=int)
a = p.parse_args()
values = {}
origins = {}
for outdir in a.outdirs:
    for path in outdir.glob('*-round*.json'):
        match = re.search(r'-round(\d+)\.json$', path.name)
        if not match:
            continue
        for result in json.loads(path.read_text())['benchmarks']:
            test = result['test']
            label = path.name.split('-' + test + '-round')[0]
            key = (test, label)
            if key in origins and origins[key] != outdir:
                raise SystemExit(f'duplicate arm across outdirs: {key}')
            origins[key] = outdir
            values.setdefault(key, {})[int(match[1])] = result['ns_per_day']

def median(test, label):
    rounds = values.get((test, label), {})
    if len(rounds) != a.rounds:
        raise SystemExit(f'{test}/{label}: {len(rounds)} rounds, expected {a.rounds}')
    return statistics.median(rounds.values())

rows = []
for test in ('gbsa', 'rf', 'pme', 'amber20-dhfr'):
    for precision, suffix in (('single', 's'), ('mixed', 'm')):
        label = a.candidate + '-' + suffix
        speed = median(test, label)
        ratio = speed / median(test, 'base-' + suffix)
        opencl = speed / median(test, 'opencl')
        rows.append(f'| {test} | {precision} | {speed:.3f} | {ratio:.4f} | {opencl:.4f} | `{origins[(test, label)]}` |')
print('| Test | Precision | Metal ns/day | / ultra-int028 Metal | / ultra-int028 OpenCL single | Raw ab.sh outdir |')
print('|---|---|---:|---:|---:|---|')
print('\n'.join(rows))

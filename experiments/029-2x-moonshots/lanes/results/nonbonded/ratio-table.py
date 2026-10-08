"""Print all 18 standard rows from raw ab.sh JSON; fail on missing arms/rounds.
usage: ratio-table.py EXPECTED_ROUNDS OUTDIR [OUTDIR ...]
"""
from collections import defaultdict
import json
from pathlib import Path
import re
import statistics
import sys
rounds = int(sys.argv[1])
tests = ['gbsa', 'rf', 'pme', 'apoa1rf', 'apoa1pme', 'apoa1ljpme',
         'amber20-dhfr', 'amber20-cellulose', 'amber20-stmv']
runs = defaultdict(dict)
sources = {}
for directory in map(Path, sys.argv[2:]):
    for path in directory.glob('*-round*.json'):
        round_number = int(re.search(r'-round(\d+)\.json$', path.name).group(1))
        payload = json.loads(path.read_text())
        if not payload['benchmarks']:
            raise RuntimeError(f'empty result: {path}')
        for result in payload['benchmarks']:
            test = result['test']
            label = path.name[:path.name.index('-'+test+'-round')]
            key = test, label
            if round_number in runs[key]:
                raise RuntimeError(f'duplicate {key} round {round_number}')
            runs[key][round_number] = result['ns_per_day']
            sources[key] = str(directory.resolve())
labels = ('base-s', 'base-m', 'cl-s', 'cand-s', 'cand-m')
for test in tests:
    for label in labels:
        if set(runs[test, label]) != set(range(1, rounds+1)):
            raise RuntimeError(f'missing rounds: {test} {label}: {runs[test,label]}')
print('Host clock. Ratios use medians of the raw rounds. Shared screens are provisional.\n')
print('| Test | Precision | Candidate ns/day | / int028 Metal | / int028 OpenCL single | Raw ab.sh outdir |')
print('|---|---|---:|---:|---:|---|')
for test in tests:
    for precision, suffix in (('single', 's'), ('mixed', 'm')):
        candidate = statistics.median(runs[test, 'cand-'+suffix].values())
        base = statistics.median(runs[test, 'base-'+suffix].values())
        opencl = statistics.median(runs[test, 'cl-s'].values())
        paths = "; ".join(dict.fromkeys(sources[test, label] for label in ("cand-"+suffix, "base-"+suffix, "cl-s")))
        print(f'| {test} | {precision} | {candidate:.2f} | {candidate/base:.4f} | {candidate/opencl:.4f} | {paths} |')

"""Report M2 paired check medians and the separately measured OpenCL denominator."""
import json, statistics, sys
from pathlib import Path
check, denominator = map(Path, sys.argv[1:3])
tests = ['gbsa','rf','pme','apoa1rf','apoa1pme','apoa1ljpme','amber20-dhfr','amber20-cellulose','amber20-stmv']
def values(pattern, directory, expected):
    files = sorted(directory.glob(pattern))
    if len(files) != expected:
        raise RuntimeError(f'{directory}/{pattern}: expected {expected}, found {len(files)}')
    return [json.loads(f.read_text())['benchmarks'][0]['ns_per_day'] for f in files]
print('| Test | Precision | Candidate ns/day | / int028 Metal | / int028 OpenCL single | Raw check directory | OpenCL denominator directory |')
print('|---|---|---:|---:|---:|---|---|')
for test in tests:
    cl = statistics.median(values(f'opencl-single-{test}-round*.json', denominator, 3))
    for precision in ['single','mixed']:
        candidate = statistics.median(values(f'cand-*-{precision}-{test}-round*.json',check,2))
        base = statistics.median(values(f'base-{precision}-{test}-round*.json',check,2))
        print(f'| {test} | {precision} | {candidate:.2f} | {candidate/base:.4f} | {candidate/cl:.4f} | {check.resolve()} | {denominator.resolve()} |')

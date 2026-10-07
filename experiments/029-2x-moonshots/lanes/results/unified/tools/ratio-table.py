"""Build the requested five-system ratio table from raw ab.sh JSON outputs."""
from pathlib import Path
import json
import statistics

root = Path('/tmp/openmm-metal-bench/ultra-m29-unified')
print('| Test | Precision | Candidate ns/day | / int028 Metal same precision | / int028 OpenCL single | Raw ab.sh outdir |')
print('|---|---|---:|---:|---:|---|')
for test in ('pme','apoa1pme','apoa1ljpme','amber20-dhfr','amber20-cellulose'):
    out = root/('screen-cellulose' if test == 'amber20-cellulose' else 'screen-dhfr-quiet' if test == 'amber20-dhfr' else 'screen-small')
    def read(label):
        values = []
        for path in sorted(out.glob(f'{label}-{test}-round*.json')):
            for result in json.loads(path.read_text())['benchmarks']:
                if result['test'] == test:
                    values.append(result['ns_per_day'])
        if len(values) != 2:
            raise SystemExit(f'Expected two successful rounds: {label} {test}: {values}')
        return statistics.median(values)
    opencl = read('opencl')
    for prec,suffix in [('single','s'),('mixed','m')]:
        cpu, base = read('cpu-'+suffix), read('base-'+suffix)
        print(f'| {test} | {prec} | {cpu:.3f} | {cpu/base:.4f} | {cpu/opencl:.4f} | [{out.name}]({out}) |')

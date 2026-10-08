"""Require both M2 rounds and print ratios plus median peak footprints."""
from pathlib import Path
import json
import re
import statistics as st

out=Path('/tmp/openmm-metal-bench/ultra-m29-unified/m2-check')
cand='cand-m29-unified-84469ab524'
print('| Test | Precision | Base ns/day | CPU FFT ns/day | Ratio | Peak footprint MiB, base → CPU |')
print('|---|---|---:|---:|---:|---:|')
for test in ('pme','apoa1pme','apoa1ljpme','amber20-dhfr','amber20-cellulose'):
    for precision in ('single','mixed'):
        values={}
        for label in ('base',cand):
            speed,mem=[],[]
            for r in (1,2):
                path=out/f'{label}-{precision}-{test}-round{r}.json'
                rows=json.loads(path.read_text())['benchmarks']
                assert len(rows)==1 and rows[0]['ns_per_day']>0, str(path)
                speed.append(rows[0]['ns_per_day'])
                m=re.search(r'(\d+)\s+peak memory footprint',path.with_suffix('.time').read_text())
                assert m, str(path)
                mem.append(int(m[1])/2**20)
            values[label]=(st.median(speed),st.median(mem))
        b,bm=values['base']; c,cm=values[cand]
        print(f'| {test} | {precision} | {b:.3f} | {c:.3f} | {c/b:.4f} | {bm:.2f} → {cm:.2f} |')

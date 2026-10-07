from pathlib import Path
from collections import defaultdict
from bisect import bisect_right
import statistics
import xml.etree.ElementTree as ET
root = Path('/tmp/openmm-metal-bench/ultra-r3-lean/shaders')
def load(path, pid):
    texts, spans = {}, defaultdict(list)
    for _, e in ET.iterparse(path, events=('end',)):
        if e.get('id') is not None:
            texts[e.get('id')] = e.text if e.tag in ('start-time', 'duration') else (e.get('fmt') or e.text or '')
        if e.tag == 'row':
            c = list(e)
            def value(x):
                return texts.get(x.get('ref')) if x.get('ref') else (x.text if x.tag in ('start-time', 'duration') else x.get('fmt') or x.text or '')
            if f'({pid})' in value(c[11]):
                name = value(c[2]).rsplit(' (', 1)[0].removeprefix('__entry_')
                if name in ('computeBondedForces', 'computeNonbonded'):
                    start, duration = int(value(c[0])), int(value(c[1]))
                    spans[name].append((start, start+duration))
            e.clear()
    return spans
def overlap(bonded, nonbonded):
    merged = []
    for a,b in sorted(nonbonded):
        if merged and a <= merged[-1][1]:
            merged[-1][1] = max(b, merged[-1][1])
        else:
            merged.append([a,b])
    ends = [b for a,b in merged]
    total = 0
    for a,b in bonded:
        i = bisect_right(ends, a)
        while i < len(merged) and merged[i][0] < b:
            total += max(0, min(b, merged[i][1])-max(a, merged[i][0]))
            i += 1
    return total/sum(b-a for a,b in bonded)
print('Mixed precision, sampled spans only. Counts are not complete dispatch counts.')
print('test arm bonded_count nonbonded_count bonded_mean_us bonded_median_us nonbonded_mean_us bonded_span_overlap_percent')
for test in ['gbsa', 'apoa1rf']:
    for arm in ['base', 'mine']:
        name = f'{arm}-{test}-mixed'
        spans = load(root/f'{name}-intervals.xml', (root/f'{name}.pypid').read_text().strip())
        bonded, nonbonded = spans['computeBondedForces'], spans['computeNonbonded']
        bd = [(b-a)/1000 for a,b in bonded]
        nd = [(b-a)/1000 for a,b in nonbonded]
        print(test, arm, len(bonded), len(nonbonded), f'{statistics.mean(bd):.3f}', f'{statistics.median(bd):.3f}', f'{statistics.mean(nd):.3f}', f'{100*overlap(bonded, nonbonded):.2f}')

"""Reduce a steady second after 25 MD updates, bounded by nonbonded starts.
Usage: steady-kernels.py intervals.xml pid [seconds=1]
The clock is xctrace GPU shader start-time/duration, in ns. This is not a host timer.
"""
import collections
import csv
import json
import sys
import xml.etree.ElementTree as ET

path, pid = sys.argv[1:3]
seconds = float(sys.argv[3]) if len(sys.argv) > 3 else 1.0
texts, rows = {}, []
for _, e in ET.iterparse(path, events=('end',)):
    if e.get('id') is not None:
        texts[e.get('id')] = e.text if e.tag in ('start-time', 'duration') else (e.get('fmt') or e.text or '')
    if e.tag == 'row':
        c = list(e)
        def value(v):
            return texts[v.get('ref')] if v.get('ref') else (v.text if v.tag in ('start-time', 'duration') else v.get('fmt') or v.text or '')
        if f'({pid})' in value(c[11]):
            name = value(c[2]).rsplit(' (', 1)[0].removeprefix('__entry_')
            rows.append((int(value(c[0]))/1000, int(value(c[1]))/1000, name))
        e.clear()
nb = sorted(t for t, d, name in rows if name == 'computeNonbonded')
if len(nb) < 3:
    raise SystemExit('Insufficient computeNonbonded spans to define a steady window')
updates = sorted(t for t, d, name in rows if name == 'integrateLangevinMiddleFused')
if len(updates) < 25:
    raise SystemExit('Fewer than 25 fused MD updates; cannot exclude initialization')
start = next(t for t in nb if t >= updates[24])
end = max(t for t in nb if t <= start+seconds*1e6)
steps = sum(start <= t < end for t in nb)
if not steps:
    raise SystemExit('No complete nonbonded-start intervals in requested window')
total, counts = collections.defaultdict(float), collections.Counter()
for t, d, name in rows:
    span = max(0, min(end, t+d)-max(start, t))
    if span:
        total[name] += span
        counts[name] += 1
print(json.dumps(dict(clock='xctrace sampled GPU shader span', source=path, pid=pid,
                     window_start_us=start, window_end_us=end, nonbonded_count=steps,
                     selection='first steady second after 25 fused MD updates',
                     fused_spans_per_step=counts['integrateLangevinMiddleFused']/steps,
                     fft_spans_per_step=counts['VkFFT_main']/steps,
                     spread_spans_per_step=counts['gridSpreadCharge']/steps)), file=sys.stderr)
writer = csv.writer(sys.stdout)
writer.writerow(['kernel', 'us_per_step', 'sampled_spans_per_step'])
for name in sorted(total, key=total.get, reverse=True):
    writer.writerow([name, f'{total[name]/steps:.6f}', f'{counts[name]/steps:.6f}'])

"""Shader-clock reciprocal windows, not isolated CPU execution times."""
import bisect
import json
import statistics as st
import sys
import xml.etree.ElementTree as ET

path, pid = sys.argv[1:3]
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
rows.sort()
updates = [t for t,d,n in rows if n == 'integrateLangevinMiddleFused']
start = updates[25]
end = start+1e6
byname = {}
for t,d,n in rows:
    byname.setdefault(n, []).append((t,t+d))
nb = byname['computeNonbonded']
nb_ends = [b for a,b in nb]
result = {'raw':path, 'clock':'xctrace GPU shader start and duration, microseconds', 'window_start_us':start, 'window_end_us':end}
for label, a_name, b_name in [('forward', 'gridSpreadCharge', 'reciprocalConvolution'), ('inverse', 'reciprocalConvolution', 'gridInterpolateForce')]:
    b_rows = byname[b_name]
    starts = [a for a,b in b_rows]
    spans, overlaps = [], []
    for a0,a1 in byname[a_name]:
        if not start <= a0 < end:
            continue
        k = bisect.bisect_left(starts, a1)
        if k == len(starts):
            continue
        b0 = starts[k]
        # Reject any incomplete capture crossing a subsequent producer.
        next_a = next((t for t,d in byname[a_name] if t > a0), float('inf'))
        if next_a < b0:
            continue
        overlap = 0
        j = bisect.bisect_right(nb_ends, a1)
        while j < len(nb) and nb[j][0] < b0:
            overlap += max(0, min(b0, nb[j][1])-max(a1,nb[j][0]))
            j += 1
        spans.append(b0-a1)
        overlaps.append(overlap)
    result[label] = dict(samples=len(spans), mean_us=st.mean(spans), median_us=st.median(spans), mean_nonbonded_overlap_us=st.mean(overlaps), mean_without_nonbonded_us=st.mean([x-y for x,y in zip(spans,overlaps)]))
result['interpretation'] = 'Producer end to consumer start includes FFT and queue/event gaps. GPU nonbonded overlap is intersected shader-clock time. Without nonbonded does not imply idle GPU or isolated critical path.'
print(json.dumps(result,indent=2))

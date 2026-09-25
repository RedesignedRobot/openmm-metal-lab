import statistics as st
secs, cur = {}, None
for line in open('raw.txt'):
    if line.startswith('=== scan.py'): break
    if line.startswith('== '): cur = secs.setdefault(line[3:].strip(), []); continue
    lab, us = line.split(); cur.append((lab, float(us)))
for name, recs in secs.items():
    steps, s = [], None
    for lab, us in recs:
        if lab == 'bounds':
            s = {}; steps.append(s)
        if s is not None:
            k = 'lsort' if lab.startswith('lsort') else lab
            s[k] = s.get(k, 0) + us
    steps = steps[50:]
    out = []
    for has in (True, False):
        rb = [x['find'] for x in steps if 'find' in x and x['find'] > 100 and ('lsort' in x) == has]
        nb = [x['nonbonded'] for x in steps if 'nonbonded' in x and ('lsort' in x) == has]
        out.append(f'{"with" if has else "w/o"} lsort: rebuilds {len(rb):4d} find/rb {st.median(rb) if rb else 0:6.1f}')
    ls = [x['lsort'] for x in steps if 'lsort' in x]
    print(f'{name:20s} ' + ' | '.join(out) + f' | lsort med {st.median(ls) if ls else 0:.1f} n {len(ls)}')

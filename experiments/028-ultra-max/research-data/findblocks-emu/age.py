# Per step: findBlocks time (rebuild if > 100 us) and computeNonbonded time from the NB_TIME records.
# Reports nonbonded by list age (steps since the last rebuild; age 0 = the rebuild step itself).
import sys, statistics as st
secs, cur = {}, None
for line in open('raw.txt'):
    if line.startswith('=== scan.py'): break
    if line.startswith('== '):
        cur = secs.setdefault(line[3:].strip(), []); continue
    lab, us = line.split(); us = float(us)
    if lab == 'find': cur.append([us, None])
    elif lab == 'nonbonded': cur[-1][1] = us
want = sys.argv[1:] or list(secs)
for name in want:
    steps = secs[name][50:]
    age, ages = None, []
    for f, nb in steps:
        age = 0 if f > 100 else (None if age is None else age+1)
        ages.append(age)
    by = {}
    for (f, nb), a in zip(steps, ages):
        if a is not None and nb is not None: by.setdefault(min(a, 4), []).append(nb)
    allnb = [nb for f, nb in steps if nb is not None]
    rate = sum(1 for f, nb in steps if f > 100)/len(steps)
    parts = '  '.join(f"age{a}{'+' if a == 4 else ''}: n={len(v)} med {st.median(v):6.1f} mean {st.mean(v):6.1f}" for a, v in sorted(by.items()))
    print(f"{name:20s} rate {rate:.2f} all mean {st.mean(allnb):6.1f} med {st.median(allnb):6.1f} | {parts}")

import statistics as st
secs, cur = {}, None
for line in open('raw.txt'):
    if line.startswith('=== scan.py'): break
    if line.startswith('== '): cur = secs.setdefault(line[3:].strip(), []); continue
    lab, us = line.split(); cur.append((lab, float(us)))
for name, recs in secs.items():
    finds = [u for l, u in recs if l == 'find']
    rb = [u for u in finds if u > 100]; ex = [u for u in finds if u <= 100]
    nb = [u for l, u in recs if l == 'nonbonded'][50:]
    labs = sorted(set(l for l, _ in recs))
    other = {l: st.median([u for ll, u in recs if ll == l]) for l in labs if l not in ('find', 'nonbonded')}
    print(f'{name:22s} steps {len(nb)+50:5d} find/rb {st.median(rb):7.1f} exit {st.median(ex):5.1f} rate {len(rb)/len(finds):.2f} nb mean {st.mean(nb):6.1f} med {st.median(nb):6.1f} p10 {sorted(nb)[len(nb)//10]:6.1f} p90 {sorted(nb)[9*len(nb)//10]:6.1f}  ', ' '.join(f'{l}={v:.1f}' for l, v in other.items() if not l.startswith('lsort') or l in ('lsort0',)))

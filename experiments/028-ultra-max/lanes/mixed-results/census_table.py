import sys, os
d = sys.argv[1]
tests = sys.argv[2].split(',')
for t in tests:
    data = {}
    for p in ('single', 'mixed'):
        rows = {}
        for line in open(os.path.join(d, f'{t}-{p}.txt')):
            _, name, count, us = line.split()
            rows[name] = (int(count), float(us))
        steps = rows['integrateLangevinMiddlePart1'][0]
        data[p] = {k: (c/steps, us/steps) for k, (c, us) in rows.items()}
    names = sorted(set(data['single']) | set(data['mixed']), key=lambda k: -(data['mixed'].get(k, (0, 0))[1]))
    ts = sum(v[1] for v in data['single'].values()); tm = sum(v[1] for v in data['mixed'].values())
    print(f'## {t}: GPU us/step single {ts:.1f}, mixed {tm:.1f}, diff {tm-ts:.1f}')
    print(f'{"kernel":45s} {"n/step":>7s} {"single":>8s} {"mixed":>8s} {"diff":>8s}')
    for k in names:
        s = data['single'].get(k, (0, 0)); m = data['mixed'].get(k, (0, 0))
        if max(s[1], m[1]) < 0.5: continue
        print(f'{k:45s} {m[0]:7.2f} {s[1]:8.1f} {m[1]:8.1f} {m[1]-s[1]:8.1f}')
    print()

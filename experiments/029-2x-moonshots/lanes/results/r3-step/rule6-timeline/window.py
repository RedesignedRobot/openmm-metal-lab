"""Bonded setup window from a timeline.dylib log: from the last library event before the first
MetalBondedUtilities buffer to the first MetalNonbondedUtilities buffer. Prints the footprint rise in
the window, the plan step (window start to the bondedPlan buffer) and the peak malloc in use."""
import glob, re, sys, collections
rows = collections.defaultdict(list)
for path in sorted(glob.glob('*.tl')):
    lines = open(path).read().splitlines()
    peak = float(lines[0].split()[1])
    ev = []
    for l in lines[1:]:
        m = re.match(r'\s*([\d.]+)\s+(\S+)\s+fp=\s*([\d.]+)\s*(.*)', l)
        if m:
            ev.append((float(m.group(1)), m.group(2), float(m.group(3)), m.group(4)))
    first_bonded = next(i for i, e in enumerate(ev) if e[1] == 'buf' and 'MetalBondedUtilities::initialize' in e[3])
    start = max(i for i in range(first_bonded) if ev[i][1].startswith("lib"))
    end = next(i for i, e in enumerate(ev) if e[1] == 'buf' and 'MetalNonbondedUtilities::initialize' in e[3])
    base_fp = ev[start][2]
    window = ev[start:end]
    rise = max(e[2] for e in window) - base_fp
    plan = ev[first_bonded][2] - base_fp
    malloc = max([float(re.search(r'malloc_in_use=([\d.]+)', e[3]).group(1)) for e in window if 'malloc_in_use' in e[3]] or [0])
    name = path.split('/')[-1][:-3]
    arm, test = name.split('-')[0], name.split('-')[1]
    rows[(test, arm)].append((rise, plan, malloc, peak))
for (test, arm), v in sorted(rows.items()):
    f = lambda k: ', '.join('%.1f' % x[k] for x in v)
    print(f'{test:11s} {arm:6s} window rise {f(0):20s} plan step {f(1):20s} malloc peak {f(2):20s} peak {f(3)}')

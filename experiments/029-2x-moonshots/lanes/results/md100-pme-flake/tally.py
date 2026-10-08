"""Old (unreconciled PME) and new verdicts for every PME row of the round 2 md100 runs.
usage: python tally.py <run dir>"""
import glob, os, re, sys
base = {}
for l in open('/tmp/openmm-metal-bench/ultra-base/forces-md100.txt'):
    f = l.split()
    if len(f) >= 6 and f[0] not in ('test', '#'):
        base[(f[0], f[2])] = (float(f[3]), float(f[4]))
runs = [p for p in glob.glob(os.path.join(sys.argv[1], '*.txt')) if re.search(r'/\w+-\d+\.txt$', p)]
key = lambda p: (int(re.search(r'-(\d+)\.txt$', p)[1]), p)
for p in sorted(runs, key=key):
    lines = open(p).read().splitlines()
    out = []
    for k, l in enumerate(lines):
        f = l.split()
        if len(f) >= 6 and f[0] in ('pme', 'apoa1pme', 'apoa1ljpme'):
            rel, mx = float(f[3]), float(f[4])
            m = re.search(r'pairs=(\d+).*raw_rel_force=(\S+) raw_max_force=(\S+)', lines[k+1])
            pairs, rrel, rmax = int(m[1]), float(m[2]), float(m[3])
            br, bm = base[(f[0], f[2])]
            old = 'FAIL' if (rrel > 2*br or rmax > 2*bm) else 'ok'
            new = 'FAIL' if (rel > 2*br or mx > 2*bm) else 'ok'
            if f[0] == 'pme' and f[2] == 'single' or pairs or old != 'ok' or new != 'ok':
                out.append(f"{f[0]}/{f[2]} pairs={pairs} raw_max={rmax:.4g} max={mx:.4g} bound={2*bm:.4g} old={old} new={new}")
    print(os.path.basename(p), '; '.join(out))

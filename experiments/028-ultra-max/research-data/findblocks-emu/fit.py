# Fit mean computeNonbonded time (job2 NB_TIME scan) to emu3 list counts. Pure python least squares.
import re, itertools
counts = {}
sysname = None
for line in open('emu3-out.txt'):
    if line.startswith('## apoa1'): sysname = 'apoa1'
    elif line.startswith('## dhfr'): sysname = 'dhfr'
    m = re.match(r'(tri|wrap) (\S+) (\d) (\d)  (\d+)  (\d+)  (\d+)  \S+  (\d+)  (\d+)  (\d+)', line)
    if m:
        s, f, mb, B, T, E, A, TP, S, SR = m.groups()
        counts[(sysname, s, float(f), int(mb), int(B))] = dict(T=int(T), F=32*int(T)-int(E), A=int(A), S=int(S), SR=int(SR))
meas = {}
for line in open('means.txt'):
    p = line.split()
    meas[(p[0], p[1])] = float(p[p.index('mean')+1])
cfg = {'new': ('tri', .08, 4, 1), 'b2': ('tri', .08, 4, 2), 'b4': ('tri', .08, 4, 4), 'wrap': ('wrap', .08, 4, 1),
       'wrapb2': ('wrap', .08, 4, 2), 'wrapb4': ('wrap', .08, 4, 4), 'mb0': ('tri', .08, 0, 1),
       'pad120': ('tri', .12, 4, 1), 'pad160': ('tri', .16, 4, 1)}
def lstsq(X, y):
    n = len(X[0])
    A = [[sum(r[i]*r[j] for r in X) for j in range(n)] for i in range(n)]
    b = [sum(r[i]*v for r, v in zip(X, y)) for i in range(n)]
    for c in range(n):
        p = max(range(c, n), key=lambda r: abs(A[r][c])); A[c], A[p] = A[p], A[c]; b[c], b[p] = b[p], b[c]
        for r in range(n):
            if r != c:
                k = A[r][c]/A[c][c]; A[r] = [x-k*z for x, z in zip(A[r], A[c])]; b[r] -= k*b[c]
    return [b[i]/A[i][i] for i in range(n)]
for test, sysn in (('pme', 'dhfr'), ('apoa1pme', 'apoa1'), ('apoa1ljpme', 'apoa1')):
    rows = [(k, counts[(sysn,)+cfg[k]], meas[(test, k)]) for k in cfg]
    for vars_ in (('T', 'SR', 'S'), ('T', 'F', 'SR', 'S'), ('T', 'F', 'SR')):
        X = [[1.0]+[c[v]/1000 for v in vars_] for _, c, _ in rows]
        y = [m for _, _, m in rows]
        co = lstsq(X, y)
        res = [m-sum(a*b for a, b in zip(co, x)) for x, m in zip(X, y)]
        rms = (sum(r*r for r in res)/len(res))**0.5
        print(f'{test:11s} vars {"+".join(vars_):10s} c0 {co[0]:7.1f}  ' + '  '.join(f'{v} {1000*c:6.3f} ns' for v, c in zip(vars_, [c/1000 for c in co[1:]])) + f'  rms {rms:.2f} us  res ' + ' '.join(f'{k}:{r:+.1f}' for (k, _, _), r in zip(rows, res)))

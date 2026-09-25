exec(open('fit.py').read().split("for test, sysn in")[0])
vars_ = ('T', 'F', 'SR', 'S')
pred_cfg = {'b4pad120': ('tri', .12, 4, 4), 'b4pad160': ('tri', .16, 4, 4), 'b4mb0': ('tri', .08, 0, 4),
            'mb0pad120': ('tri', .12, 0, 1), 'b4mb0pad120': ('tri', .12, 0, 4), 'b4mb0pad160': ('tri', .16, 0, 4),
            'mb2': ('tri', .08, 2, 1), 'mb1': ('tri', .08, 1, 1), 'b4mb2': ('tri', .08, 2, 4)}
for test, sysn in (('pme', 'dhfr'), ('apoa1pme', 'apoa1'), ('apoa1ljpme', 'apoa1')):
    rows = [(k, counts[(sysn,)+cfg[k]], meas[(test, k)]) for k in cfg]
    X = [[1.0]+[c[v]/1000 for v in vars_] for _, c, _ in rows]
    y = [m for _, _, m in rows]
    co = lstsq(X, y)
    loo = []
    for h in range(len(rows)):
        c2 = lstsq(X[:h]+X[h+1:], y[:h]+y[h+1:])
        loo.append(f'{rows[h][0]}:{y[h]-sum(a*b for a, b in zip(c2, X[h])):+.1f}')
    print(test, 'LOO residuals (measured - predicted from the other 8):', ' '.join(loo))
    out = []
    for k, c in pred_cfg.items():
        c = counts[(sysn,)+c]
        out.append(f'{k} {sum(a*b for a, b in zip(co, [1.0]+[c[v]/1000 for v in vars_])):.1f}')
    print('   predicted nonbonded:', ', '.join(out))

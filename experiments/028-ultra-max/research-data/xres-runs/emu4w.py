# emu4w: x adds removed against the neighbor-list walk width W (contiguous walk), after emu4defs.py.
def wcurve(name, pos, N, L, rc, excl, Bs, Ws=(4800, 3600, 2400, 1800, 1200, 900, 600)):
    units, SR = build(rows4(pos, N, L, rc, excl, 0.08), (4, 0), Bs)
    rng = np.random.default_rng(1)
    print(f'## {name}')
    for mb in (4, 0):
        for B in Bs:
            U = units[(mb, B)]
            T = sum(len(a) for _, a in U)
            for oname, idx in (('as written', rng.permutation(len(U))), ('by x', np.arange(len(U)))):
                trow = np.concatenate([np.full(len(U[k][1]), U[k][0], np.int64) for k in idx])
                tat = np.concatenate([U[k][1] for k in idx])
                cells = []
                for W in Ws:
                    runs, _, _ = walk(trow, tat, W, 'chunk')
                    cells.append(f'W{W} {T/W:.1f}t {1-runs/T:.3f}')
                print(f'mb{mb} B{B} {oname:10s} ' + '  '.join(cells))
    sys.stdout.flush()

files = {}
tf = tarfile.open(fileobj=io.BytesIO(base64.b64decode(CAPTURES)), mode='r:gz')
for m in tf.getmembers():
    if m.isfile():
        files[m.name] = tf.extractfile(m).read()
gpos, gN, gL, gexcl = dhfr_positions(0, '1')
wcurve('rf (dhfr, cutoff 1.0)', gpos, gN, gL, 1.0, gexcl, (1, 4))
wcurve('pme (dhfr, cutoff 0.9)', gpos, gN, gL, 0.9, gexcl, (1, 4))
pos, N, L, excl, _ = load_capture(files, 'pme')
wcurve('apoa1rf (cutoff 1.0)', pos, N, L, 1.0, excl, (1,))
wcurve('apoa1pme (cutoff 0.9)', pos, N, L, 0.9, excl, (1,))

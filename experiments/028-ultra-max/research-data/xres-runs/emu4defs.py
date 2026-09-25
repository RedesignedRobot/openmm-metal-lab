# emu4: run statistics for an x-resident computeNonbonded. Runs after caps_b64.py and emu2defs.py.
# Per test it rebuilds the tiles findBlocks (163f2838e, same kernel as ultra/integrated) writes at
# padding 0.08, MAX_BITS 4 and 0, batch 1, 2 and 4, and keeps the flush groups: a SIMD group stores
# floor(n/32) tiles as one contiguous block of the list once its buffer holds more than 224 atoms, and
# the rest at the end of its row share (findInteractingBlocks.metal:652-668 and 692-703). It then walks
# the list the way computeNonbonded hands tiles to SIMD groups and measures runs: maximal sequences of
# consecutive tiles in one SIMD group's walk with the same x block. An x-resident kernel writes the
# x-side forces once per run instead of once per tile.
#   stride: today's walk, pos = warp + k*totalWarps (nonbonded.metal:242)
#   chunk:  warp w takes tiles [w*T/W, (w+1)*T/W), the no-cutoff walk (nonbonded.metal:249-250)
# List orders: 'as written' puts flush groups in random order (the atomicAdd on interactionCount[0]
# decides it); 'by x' puts every tile of a row next to each other (a sort by x, or merging the batch
# shares of a row, which are the only tiles with the same x).
WARPS = {'ultra': 2400*64//32, 'm2': 400*64//32}
HIST = [(1, 1), (2, 2), (3, 4), (5, 8), (9, 16), (17, 10**9)]

def rows4(pos, N, L, rc, excl, f):
    NB = (N+31)//32
    idx = np.arange(NB*32)
    src = np.where(idx < N, idx, 0)
    P = pos[src].reshape(NB, 32, 3).astype(np.float32)
    valid = (idx < N).reshape(NB, 32)
    center, size, w = block_bounds(P, L)
    ss = f16_ru(size)
    order, _ = sort_order(size)
    sc, sw = center[order], w[order]
    PC = rc*(1+f)
    j = np.arange(NB)
    lane = np.arange(32)[None, :]
    for i in range(NB):
        x = order[i]
        d = wrap_delta(sc[i]-sc, L)
        d2 = (d*d).sum(1)
        bb = np.maximum(0.0, np.abs(d)-ss[x]-ss[order])
        ok = (j > i) & (d2 < (PC+sw[i]+sw)**2) & ((bb*bb).sum(1) < PC*PC)
        js = np.nonzero(ok)[0]
        ys = order[js]
        exc = np.array([y in excl[x] for y in ys], bool)
        js, ys = js[~exc], ys[~exc]
        if len(js) == 0:
            continue
        cx = center[x]
        p1 = P[x] - np.floor((P[x]-cx)/L + 0.5)*L
        p2 = P[ys] - np.floor((P[ys]-cx)/L + 0.5)*L
        dc = wrap_delta(p1[None, :, :]-center[ys][:, None, :], L)
        flags = (dc*dc).sum(2) < (PC+w[ys])[:, None]**2
        dd = p2[:, :, None, :]-p1[None, None, :, :]
        r2 = (dd*dd).sum(3)
        vv = valid[x][None, None, :] & valid[ys][:, :, None]
        cnt = ((r2 < PC*PC) & vv & flags[:, None, :]).sum(2)
        real = ((r2 < rc*rc) & vv).sum(2)
        yield i, js - (i+1)//32*32, cnt, real, (ys[:, None]*32 + lane).astype(np.int32)

def build(gen, mbs, Bs):
    units = {(mb, B): [] for mb in mbs for B in Bs}    # flush groups in row-major order: (row, tiles x 32 atom ids)
    SR = {mb: 0 for mb in mbs}
    for i, pos_scan, cnt, real, ids_all in gen:
        chunk = pos_scan//32
        for mb in mbs:
            tile_e = cnt > mb
            SR[mb] += int(real[(cnt > 0) & (cnt <= mb)].sum())
            inc_all = tile_e.sum(1)
            for B in Bs:
                share = chunk % B
                for b in range(B):
                    c = share == b
                    inc = inc_all[c]
                    tot = int(inc.sum())
                    if tot == 0:
                        continue
                    sizes, n = [], 0
                    for v in inc.tolist():
                        n += v
                        if n > 224:
                            t = n//32
                            sizes.append(t)
                            n -= 32*t
                    if n > 0:
                        sizes.append((n+31)//32)
                    T = sum(sizes)
                    buf = np.full(T*32, -1, np.int32)
                    buf[:tot] = ids_all[c][tile_e[c]]
                    buf = buf.reshape(T, 32)
                    k = 0
                    for s in sizes:
                        units[(mb, B)].append((i, buf[k:k+s]))
                        k += s
    return units, SR

def walk(trow, tat, W, kind):
    T = len(trow)
    if kind == 'stride':
        perm = np.argsort(np.arange(T) % W, kind='stable')
        wv = perm % W
    else:
        perm = np.arange(T)
        wv = np.searchsorted((np.arange(W+1)*T)//W, perm, side='right')-1
    r = trow[perm]
    same_warp = np.zeros(T, bool)
    same_warp[1:] = wv[1:] == wv[:-1]
    brk = ~same_warp
    brk[1:] |= r[1:] != r[:-1]
    starts = np.nonzero(brk)[0]
    lens = np.diff(np.append(starts, T))
    A = tat[perm]
    ym = int(((A[1:] == A[:-1]) & (A[1:] >= 0) & same_warp[1:, None]).sum())
    hist = [lens[(lens >= lo) & (lens <= hi)].sum()/T for lo, hi in HIST]
    return len(starts), ym, hist

def run(name, pos, N, L, rc, excl, mbs=(4, 0), Bs=(1, 2, 4)):
    t0 = time.time()
    NB = (N+31)//32
    ET = sum(sum(1 for y in excl[x] if y >= x) for x in range(NB))
    units, SR = build(rows4(pos, N, L, rc, excl, 0.08), mbs, Bs)
    print(f'## {name}: N={N} blocks={NB} rc={rc} exclusion tiles={ET}  ({time.time()-t0:.0f} s)')
    print('   hist columns: share of tiles in runs of length 1, 2, 3-4, 5-8, 9-16, 17+')
    rng = np.random.default_rng(1)
    for mb in mbs:
        for B in Bs:
            U = units[(mb, B)]
            T = sum(len(a) for _, a in U)
            rows_with = len(set(i for i, _ in U))
            real_slots = sum(int((a >= 0).sum()) for _, a in U)
            adds = 96*T + 3*real_slots + 6*SR[mb] + 192*ET
            print(f'mb{mb} B{B}: tiles {T}  flush groups {len(U)}  rows {rows_with}  tiles/row {T/rows_with:.2f}  '
                  f'tiles/group {T/len(U):.2f}  in-range singles {SR[mb]}  64-bit adds/step {adds}  x-side share {96*T/adds:.3f}')
            print(f'   bound, one SIMD group per flush group: x adds removed {1-len(U)/T:.3f}; per row: {1-rows_with/T:.3f}')
            for oname, idx in (('as written', rng.permutation(len(U))), ('by x', np.arange(len(U)))):
                trow = np.concatenate([np.full(len(U[k][1]), U[k][0], np.int64) for k in idx])
                tat = np.concatenate([U[k][1] for k in idx])
                for wname, W in WARPS.items():
                    for kind in ('stride', 'chunk'):
                        runs, ym, hist = walk(trow, tat, W, kind)
                        print(f'   {oname:10s} {kind:6s} {wname:5s} W={W:4d} tiles/warp {T/W:5.2f}  runs {runs}  mean run {T/runs:.2f}  '
                              f'x adds removed {1-runs/T:.3f}  of all adds {96*(T-runs)/adds:.3f}  y lane repeats {ym/real_slots:.4f}  '
                              f'hist {" ".join(f"{h:.3f}" for h in hist)}')
            sys.stdout.flush()

def cellulose_positions():
    import openmm as mm
    from openmm import unit, app
    D = '/tmp/openmm-metal-bench/ultra-base/benchmarks/Amber20_Benchmark_Suite/PME'
    prmtop = app.AmberPrmtopFile(D+'/Topologies/Cellulose.prmtop')
    inpcrd = app.AmberInpcrdFile(D+'/Coordinates/Cellulose.inpcrd')
    system = prmtop.createSystem(nonbondedMethod=app.PME, nonbondedCutoff=0.9*unit.nanometer, constraints=app.HBonds)
    bv = [v.value_in_unit(unit.nanometer) for v in inpcrd.boxVectors]
    print('cellulose box vectors', [[round(c, 4) for c in v] for v in bv])
    assert all(abs(bv[a][b]) < 1e-6 for a in range(3) for b in range(3) if a != b), 'triclinic box'
    L = np.array([bv[0][0], bv[1][1], bv[2][2]])
    pos = np.array(inpcrd.getPositions(asNumpy=True).value_in_unit(unit.nanometer))
    N = system.getNumParticles()
    top = prmtop.topology
    water = [r for r in top.residues() if r.name in ('WAT', 'HOH')]
    print('cellulose residues', top.getNumResidues(), 'waters', len(water), 'atoms', N)
    wat_atoms = np.array([[a.index for a in r.atoms()] for r in water])
    nonwat = np.setdiff1d(np.arange(N), wat_atoms.ravel())
    # Waters are permuted among their slots by Hilbert bin of the molecule center (reorderAtomsImpl,
    # 255 bins, since there are more than 5000). Cellulose chains stay in place (inference: permuting
    # identical chains among themselves moves whole chains and leaves the block structure alone).
    cen = pos[wat_atoms].mean(1)
    cen = cen - np.floor(cen/L)*L
    bw = L.max()/255.0
    c = (cen/bw).astype(np.int64)
    h = hilbert3(c[:, 0], c[:, 1], c[:, 2])
    worder = np.lexsort((np.arange(len(water)), h))
    new_index = np.concatenate([nonwat, wat_atoms[worder].ravel()])
    gpos = pos[new_index]
    nb = next(f for f in system.getForces() if isinstance(f, mm.NonbondedForce))
    slot = np.empty(N, np.int64)
    slot[new_index] = np.arange(N)
    NB = (N+31)//32
    excl = [set() for _ in range(NB)]
    for e in range(nb.getNumExceptions()):
        a, b, *_ = nb.getExceptionParameters(e)
        ba, bb_ = slot[a]//32, slot[b]//32
        excl[ba].add(bb_)
        excl[bb_].add(ba)
    for x in range(NB):
        excl[x].add(x)
    return gpos, N, L, excl


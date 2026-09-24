# Emulates the Metal findBlocksWithInteractions (6df2b8bcb, HIP-derived, batch 1) on real positions
# in GPU atom order, for several paddings. CPU only. Reports candidate counts per row (triangle,
# wrap, batch splits), atoms tested per candidate (popcount of atomFlags), single pairs, tile atoms
# and tiles. Validation: with MAX_BITS 0 at OpenCL's padding, tile atoms must equal lab 009's counts.
import sys, io, os, tarfile, base64, json, time
import numpy as np

FRACS = [0.06, 0.08, 0.10, 0.12, 0.14, 0.16, 0.20, 0.25, 0.30]

def wrap_delta(d, L):
    return d - np.floor(d/L + 0.5)*L

def f16_ru(a):
    h = a.astype(np.float16)
    lo = h.astype(np.float32) < a
    h[lo] = np.nextafter(h[lo], np.float16(np.inf))
    return h.astype(np.float32)

def block_bounds(P, L):
    # P: (NB, 32, 3) positions per block, padding lanes already filled.
    p0 = P[:, 0, :] - np.floor(P[:, 0, :]/L)*L
    mn = p0.copy()
    mx = p0.copy()
    for i in range(1, 32):
        c = 0.5*(mx+mn)
        p = P[:, i, :]
        p = p - np.floor((p-c)/L + 0.5)*L
        mn = np.minimum(mn, p)
        mx = np.maximum(mx, p)
    size = 0.5*(mx-mn)
    center = 0.5*(mx+mn)
    d = wrap_delta(P - center[:, None, :], L)
    w = np.sqrt((d*d).sum(2).max(1))
    return center.astype(np.float32), size.astype(np.float32), w.astype(np.float32)

def sort_order(size):
    tot = size.sum(1)
    lo = np.log(tot[tot > 0].min())
    hi = np.log(tot.max())
    b = ((np.log(np.maximum(tot, 1e-30))-lo)*(20.0/(hi-lo))).astype(np.int64)
    b = np.clip(b, 0, 19)
    return np.lexsort((np.arange(len(tot)), b)), b

def emulate(name, pos, N, L, rc, excl, pad_lane='zero', fracs=FRACS, maxbits=4, validate=None, ref_order=None):
    t0 = time.time()
    NB = (N+31)//32
    idx = np.arange(NB*32)
    if pad_lane == 'zero':
        src = np.where(idx < N, idx, 0)                   # 6df2b8bcb: lanes past numAtoms load atom 0
    else:
        src = np.where(idx < N, idx, (idx//32)*32)        # fix: load the block's first atom
    P = pos[src].reshape(NB, 32, 3).astype(np.float32)
    valid = (idx < N).reshape(NB, 32)
    center, size, w = block_bounds(P, L)
    size16 = f16_ru(size)
    order, bins = sort_order(size)
    if ref_order is not None:
        print(f'{name}: emulated sort order matches the captured sortedBlocks at {(order == ref_order).mean()*100:.2f}% of positions')
    rank = np.empty(NB, np.int64)
    rank[order] = np.arange(NB)
    sc, ss, sw = center[order], size16[order], w[order]
    PCs = [rc*(1+f) for f in fracs]
    nP = len(PCs)
    PCmax = max(PCs)
    # Per padding accumulators
    cand_tri = np.zeros((nP, NB), np.int64)      # candidates of row i (sorted index) with j > i
    cand_wrap = np.zeros((nP, NB), np.int64)
    k_tri = np.zeros((nP, NB), np.int64)         # sum of popcount(atomFlags) over row i's candidates
    cand_b = {B: np.zeros((nP, NB, B), np.int64) for B in (2, 4)}
    excl_cand = np.zeros(nP, np.int64)
    empty_cand = np.zeros(nP, np.int64)
    single_cand = np.zeros(nP, np.int64)
    single_pairs = np.zeros(nP, np.int64)
    tile_atoms = np.zeros(nP, np.int64)
    tiles = np.zeros(nP, np.int64)
    tile_atoms_mb0 = np.zeros(nP, np.int64)
    tiles_mb0 = np.zeros(nP, np.int64)
    kvals = [[] for _ in range(nP)]
    half = NB//2
    for i in range(NB):
        x = order[i]
        d = wrap_delta(sc[i]-sc, L)
        d2 = (d*d).sum(1)
        bb = np.maximum(0.0, np.abs(d)-ss[i]-ss)
        bb2 = (bb*bb).sum(1)
        j_all = np.arange(NB)
        others = j_all != i
        # wrap ownership: row i owns j when 1 <= (j-i) mod NB < NB/2, plus the half-apart pair for the lower row
        off = (j_all - i) % NB
        own_wrap = (off >= 1) & ((off < (NB+1)//2) | ((NB % 2 == 0) & (off == half) & (i < j_all)))
        tri = j_all > i
        for p, PC in enumerate(PCs):
            ok = others & (d2 < (PC+sw[i]+sw)**2) & (bb2 < PC*PC)
            cand_tri[p, i] = int((ok & tri).sum())
            cand_wrap[p, i] = int((ok & own_wrap).sum())
            c0 = (i+1)//32
            ch = j_all//32
            for B in (2, 4):
                sel = ok & tri
                wsel = (ch[sel]-c0) % B
                cand_b[B][p, i] = np.bincount(wsel, minlength=B)
        # Atom level work for the triangle candidates at the largest padding, then each padding is a subset.
        okmax = others & tri & (d2 < (PCmax+sw[i]+sw)**2) & (bb2 < PCmax*PCmax)
        js = np.nonzero(okmax)[0]
        if len(js) == 0:
            continue
        ys = order[js]
        cx = center[x]
        p1 = P[x] - np.floor((P[x]-cx)/L + 0.5)*L                  # singlePeriodicCopy wrap to block x center
        p2 = P[ys] - np.floor((P[ys]-cx)/L + 0.5)*L                # (k, 32, 3)
        cy = center[ys]
        dc = wrap_delta(p1[None, :, :]-cy[:, None, :], L)          # (k, 32 x atoms, 3)
        dc2 = (dc*dc).sum(2)
        dd = p2[:, :, None, :]-p1[None, None, :, :]                 # (k, 32 y, 32 x, 3)
        dist2 = (dd*dd).sum(3)
        vx = valid[x]
        vy = valid[ys]                                              # (k, 32)
        exc = np.array([y in excl[x] for y in ys]) if excl is not None else np.zeros(len(ys), bool)
        rowatoms = np.zeros(nP, np.int64)
        rowatoms0 = np.zeros(nP, np.int64)
        for p, PC in enumerate(PCs):
            okp = (d2[js] < (PC+sw[i]+sw[js])**2) & (bb2[js] < PC*PC)
            if not okp.any():
                continue
            flags = (dc2[okp] < (PC+w[ys[okp]])[:, None]**2)        # (kp, 32 x)
            kk = flags.sum(1)
            k_tri[p, i] = int(kk.sum())
            kvals[p].append(kk)
            inter = (dist2[okp] < PC*PC) & vx[None, None, :] & vy[okp][:, :, None]
            inter[exc[okp]] = False
            cnt = inter.sum(2)                                      # (kp, 32 y) interacting x atoms per y atom
            excl_cand[p] += int(exc[okp].sum())
            empty_cand[p] += int((cnt.sum(1) == 0).sum())
            sgl = (cnt > 0) & (cnt <= maxbits)
            single_cand[p] += int(sgl.any(1).sum())
            single_pairs[p] += int(cnt[sgl].sum())
            rowatoms[p] = int((cnt > maxbits).sum())
            rowatoms0[p] = int((cnt > 0).sum())
        tile_atoms += rowatoms
        tiles += (rowatoms+31)//32
        tile_atoms_mb0 += rowatoms0
        tiles_mb0 += (rowatoms0+31)//32
    print(f'## {name}: N={N} NB={NB} rc={rc} box={L:.3f} pad_lane={pad_lane} sizebins={np.bincount(bins, minlength=20).tolist()} ({time.time()-t0:.0f} s)')
    last = NB-1
    print(f'last block: rank {rank[last]} of {NB}, half-size {size[last].round(3).tolist()}, radius {w[last]:.3f}; median block half-size {np.median(size, 0).round(3).tolist()}, median radius {np.median(w):.3f}')
    print('pad/rc  cand  cand/row  tri_max  tri_p99  wrap_max  wrap_p99  b2_max  b4_max  kmean  k_p10/50/90  excl_cand  empty_cand  cand_with_singles  single_pairs  tile_atoms  tiles  tiles_mb0  tile_atoms_mb0')
    for p, f in enumerate(fracs):
        ct = cand_tri[p]
        kv = np.concatenate(kvals[p]) if kvals[p] else np.array([0])
        tot = int(ct.sum())
        print(f'{f:.2f}  {tot}  {tot/NB:.1f}  {ct.max()}  {int(np.percentile(ct, 99))}  {cand_wrap[p].max()}  {int(np.percentile(cand_wrap[p], 99))}  '
              f'{cand_b[2][p].max()}  {cand_b[4][p].max()}  {kv.mean():.1f}  {np.percentile(kv, 10):.0f}/{np.percentile(kv, 50):.0f}/{np.percentile(kv, 90):.0f}  '
              f'{excl_cand[p]}  {empty_cand[p]}  {single_cand[p]}  {single_pairs[p]}  {tile_atoms[p]}  {tiles[p]}  {tiles_mb0[p]}  {tile_atoms_mb0[p]}')
    if validate:
        print('validation (OpenCL at pad 0.10, MAX_BITS 0):', validate)
    # Row chain inputs for the latency model at base padding (index of 0.08)
    p = fracs.index(0.08)
    ct, cw = cand_tri[p], cand_wrap[p]
    rows_sorted = np.argsort(-ct)[:5]
    print('base pad: top rows by candidates (sorted index: tri candidates, chunks):', [(int(r), int(ct[r]), int((NB+31)//32 - (r+1)//32)) for r in rows_sorted])
    print('base pad: row-sum k max (tri) =', int(k_tri[p].max()), ' mean =', round(float(k_tri[p].mean()), 1))
    sys.stdout.flush()

def load_capture(files, prefix):
    md = json.loads(files[prefix+'/metadata.json'])
    N = md['numAtoms']
    posq = np.frombuffer(files[prefix+'/posq.bin'], dtype=np.float32).reshape(-1, 4)[:N, :3].astype(np.float64)
    ei = np.frombuffer(files[prefix+'/exclusionIndices.bin'], dtype=np.uint32)
    er = np.frombuffer(files[prefix+'/exclusionRowIndices.bin'], dtype=np.uint32)
    NB = md['numBlocks']
    excl = [set(ei[er[x]:er[x+1]].tolist()) for x in range(NB)]
    sb = np.frombuffer(files[prefix+'/sortedBlocks_after_sort.bin'], dtype=np.uint32)[:NB]
    mask = (1 << int(np.ceil(np.log2(NB+1)))) - 1
    return posq, N, md['periodicBoxSize'][0], excl, (sb & 0xFFF).astype(np.int64)

def hilbert3(x, y, z, bits=8):
    X = [x.astype(np.int64), y.astype(np.int64), z.astype(np.int64)]
    M = 1 << (bits-1)
    Q = M
    while Q > 1:
        P = Q-1
        for i in range(3):
            m = (X[i] & Q) != 0
            X[0] = np.where(m, X[0] ^ P, X[0])
            t = np.where(~m, (X[0] ^ X[i]) & P, 0)
            X[0] = X[0] ^ t
            X[i] = X[i] ^ t
        Q >>= 1
    for i in range(1, 3):
        X[i] ^= X[i-1]
    t = np.zeros_like(X[0])
    Q = M
    while Q > 1:
        t = np.where((X[2] & Q) != 0, t ^ (Q-1), t)
        Q >>= 1
    for i in range(3):
        X[i] ^= t
    h = np.zeros_like(X[0])
    for b in range(bits-1, -1, -1):
        for i in range(3):
            h = (h << 1) | ((X[i] >> b) & 1)
    return h

def dhfr_positions(steps, threads):
    B = '/tmp/openmm-metal-bench/ultra-base/benchmarks'
    os.chdir(B)
    src = open(os.path.join(B, 'benchmark.py')).read()
    bm = type(sys)('benchmark')
    exec(compile(src[:src.index('def runOneTest(')], 'benchmark.py', 'exec'), bm.__dict__)
    import openmm as mm
    from openmm import unit, app
    system, positions, params = bm.retrieveTestSystem('pme')
    integ = mm.LangevinMiddleIntegrator(300*unit.kelvin, 1/unit.picoseconds, 0.004*unit.picoseconds)
    integ.setConstraintTolerance(1e-5)
    ctx = mm.Context(system, integ, mm.Platform.getPlatformByName('CPU'), {'Threads': threads})
    ctx.setPositions(positions)
    ctx.setVelocitiesToTemperature(300*unit.kelvin)
    integ.step(steps)
    st = ctx.getState(getPositions=True)
    pos = st.getPositions(asNumpy=True).value_in_unit(unit.nanometer)
    L = st.getPeriodicBoxVectors()[0][0].value_in_unit(unit.nanometer)
    top = app.PDBFile('5dfr_solv-cube_equil.pdb').topology
    N = system.getNumParticles()
    water = [r for r in top.residues() if r.name == 'HOH']
    wat_atoms = np.array([[a.index for a in r.atoms()] for r in water])
    nonwat = np.setdiff1d(np.arange(N), wat_atoms.ravel())
    # ComputeContext::reorderAtomsImpl: identical molecules are permuted among their slots, by Hilbert bin
    # of the molecule center (waters: 7023 > 5000 molecules, 255 bins over the box). The protein stays put.
    cen = pos[wat_atoms].mean(1)
    cen = cen - np.floor(cen/L)*L
    bw = L/255.0
    c = (cen/bw).astype(np.int64)
    h = hilbert3(c[:, 0], c[:, 1], c[:, 2])
    worder = np.lexsort((np.arange(len(water)), h))
    new_index = np.concatenate([nonwat, wat_atoms[worder].ravel()])   # GPU slot -> original atom
    gpos = pos[new_index]
    nb = next(f for f in system.getForces() if isinstance(f, mm.NonbondedForce))
    slot = np.empty(N, np.int64)
    slot[new_index] = np.arange(N)
    NB = (N+31)//32
    excl = [set() for _ in range(NB)]
    for e in range(nb.getNumExceptions()):
        a, b, *_ = nb.getExceptionParameters(e)
        ba, bb = slot[a]//32, slot[b]//32
        excl[ba].add(bb)
        excl[bb].add(ba)
    for x in range(NB):
        excl[x].add(x)
    return gpos, N, L, excl

if __name__ == '__main__':
    mode = sys.argv[1]
    if mode == 'cap':
        files = {}
        tf = tarfile.open(fileobj=io.BytesIO(base64.b64decode(CAPTURES)), mode='r:gz')
        for m in tf.getmembers():
            if m.isfile():
                files[m.name] = tf.extractfile(m).read()
        for prefix, rc, val in (('rf', 1.0, '55,396 tiles, 1,727,984 tile atoms'), ('pme', 0.9, '43,560 tiles, 1,349,142 tile atoms')):
            pos, N, L, excl, ref = load_capture(files, prefix)
            emulate('apoa1'+prefix+' (lab 009 capture, step 200)', pos, N, L, rc, excl, validate=val, ref_order=ref)
    else:
        gpos, N, L, excl = dhfr_positions(int(sys.argv[2]), sys.argv[3])
        for rc in (1.0, 0.9):
            emulate(f'dhfr rc {rc} (CPU trajectory, emulated reorder)', gpos, N, L, rc, excl, 'zero')
        emulate('dhfr rc 0.9, padding lanes load the block\'s first atom', gpos, N, L, 0.9, excl, 'first', fracs=[0.08])

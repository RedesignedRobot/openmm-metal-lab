# emu3: what computeNonbonded (163f2838e) has to do with the list findBlocks writes under each knob.
# Runs after emu2's definitions (block_bounds, f16_ru, sort_order, wrap_delta, load_capture, dhfr_positions)
# and CAPTURES. Per config it counts tiles, empty slots, active j-steps (steps where at least one lane has
# r < rc, so the SIMD group runs the interaction body), in-range pairs in tiles, single pairs, and single
# pairs inside the real cutoff (only those run the body and the six 64-bit atomics).
import itertools

T_IDX = (np.arange(32)[None, :] + np.arange(32)[:, None]) % 32     # [t, i] -> slot lane i sees at step t
I_IDX = np.broadcast_to(np.arange(32)[None, :], (32, 32))

def rows(pos, N, L, rc, excl, f, scheme):
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
    half = NB//2
    for i in range(NB):
        x = order[i]
        d = wrap_delta(sc[i]-sc, L)
        d2 = (d*d).sum(1)
        bb = np.maximum(0.0, np.abs(d)-ss[x]-ss[order])
        j = np.arange(NB)
        ok = (j != i) & (d2 < (PC+sw[i]+sw)**2) & ((bb*bb).sum(1) < PC*PC)
        if scheme == 'tri':
            ok &= j > i
            scan = j
        else:
            off = (j-i) % NB
            ok &= (off >= 1) & ((off < (NB+1)//2) | ((NB % 2 == 0) & (off == half) & (i < j)))
            scan = np.where(j > i, j, j+NB)
        js = np.nonzero(ok)[0]
        js = js[np.argsort(scan[js], kind='stable')]
        ys = order[js]
        exc = np.array([y in excl[x] for y in ys], bool)
        js, ys = js[~exc], ys[~exc]
        if len(js) == 0:
            yield i, np.zeros(0, np.int64), None, None
            continue
        cx = center[x]
        p1 = P[x] - np.floor((P[x]-cx)/L + 0.5)*L
        p2 = P[ys] - np.floor((P[ys]-cx)/L + 0.5)*L
        dc = wrap_delta(p1[None, :, :]-center[ys][:, None, :], L)
        flags = (dc*dc).sum(2) < (PC+w[ys])[:, None]**2                   # (k, 32 x) atomFlags
        dd = p2[:, :, None, :]-p1[None, None, :, :]
        r2 = (dd*dd).sum(3)                                                 # (k, 32 y, 32 x)
        vv = valid[x][None, None, :] & valid[ys][:, :, None]
        pad = (r2 < PC*PC) & vv & flags[:, None, :]
        real = (r2 < rc*rc) & vv
        pos_scan = scan[js] - (i+1)//32*32
        yield i, pos_scan, pad.sum(2), real

def count(gen, mbs, Bs):
    acc = {(mb, B): np.zeros(8, np.int64) for mb in mbs for B in Bs}
    kdist = {mb: np.zeros(33, np.int64) for mb in mbs}   # real-range pairs per tile slot
    for i, pos_scan, cnt, real in gen:
        if cnt is None:
            continue
        for mb in mbs:
            tile_e = cnt > mb
            sgl = (cnt > 0) & (cnt <= mb)
            ns = int(cnt[sgl].sum())
            nsr = int(real[sgl].sum())
            kdist[mb] += np.bincount(real[tile_e].sum(1), minlength=33)
            for B in Bs:
                wsel = (pos_scan//32) % B
                a = acc[(mb, B)]
                for b in range(B):
                    c = wsel == b
                    M = real[c][tile_e[c]]                                   # (E, 32 x) in scan, then lane order
                    E = len(M)
                    if E == 0:
                        continue
                    T = (E+31)//32
                    M = np.concatenate([M, np.zeros((T*32-E, 32), bool)]).reshape(T, 32, 32)
                    act = M[:, T_IDX, I_IDX].any(2)                           # (T, 32 steps)
                    a += [T, T*32-E, int(act.sum()), int(M.sum()), 0, 0, 0, 0]
                a[4] += ns
                a[5] += nsr
    return acc, kdist

def run(name, pos, N, L, rc, excl):
    print(f'## {name}: N={N} rc={rc}')
    print('scheme pad maxbits B  tiles  empty_slots  active_steps  act/tile  tile_pairs_real  singles  singles_real  real_frac')
    plan = [('tri', 0.08, (4, 2, 1, 0), (1, 2, 4)), ('tri', 0.12, (4, 0), (1, 4)), ('tri', 0.16, (4, 0), (1, 4)),
            ('wrap', 0.08, (4, 0), (1, 2, 4))]
    for scheme, f, mbs, Bs in plan:
        t0 = time.time()
        acc, kdist = count(rows(pos, N, L, rc, excl, f, scheme), mbs, Bs)
        for mb in mbs:
            for B in Bs:
                T, es, act, tp, ns, nsr, _, _ = acc[(mb, B)]
                print(f'{scheme} {f:.2f} {mb} {B}  {T}  {es}  {act}  {act/T:.2f}  {tp}  {ns}  {nsr}  {nsr/max(ns, 1):.3f}')
        for mb in mbs:
            print(f'  {scheme} {f:.2f} mb{mb} real pairs per tile slot, counts for k=0..12:', kdist[mb][:13].tolist(), f'mean {np.dot(np.arange(33), kdist[mb])/kdist[mb].sum():.2f}')
        print(f'  ({time.time()-t0:.0f} s)')
        sys.stdout.flush()

files = {}
tf = tarfile.open(fileobj=io.BytesIO(base64.b64decode(CAPTURES)), mode='r:gz')
for m in tf.getmembers():
    if m.isfile():
        files[m.name] = tf.extractfile(m).read()
pos, N, L, excl, _ = load_capture(files, 'pme')
run('apoa1 pme capture (apoa1pme and apoa1ljpme lists)', pos, N, L, 0.9, excl)
gpos, N, L, excl = dhfr_positions(0, '1')
run('dhfr (pme test)', gpos, N, L, 0.9, excl)

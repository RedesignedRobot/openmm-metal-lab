"""Q2 census, CPU only: survival of 8x4 masked units in the real Metal neighbor list.

A unit is 8 x atoms (i = lane&7 of cluster c) by 4 y slots (j = lane>>3 of quad q), 32 units per 32x32 tile.
The mask is built at list time with the padded cutoff, so it stays valid for the list lifetime; s is the fraction
of units with at least one valid pair inside the padded cutoff. Also reported: the oracle s at the plain cutoff at
list age 0 and 2, empty 4- and 8-slot y chunks (no pair with any of the 32 x atoms inside the padded cutoff), and
the same numbers on a modeled c16 half-tile list and on a repacked list at a smaller cutoff (apoa1pme from the
apoa1rf dump).
usage: census.py <dump dir> [cutoff override for a repacked list] [moves npz for age 2]
"""
import json
import sys
from pathlib import Path

import numpy as np

d = Path(sys.argv[1])
cut_override = float(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] != "-" else None
moves_path = sys.argv[3] if len(sys.argv) > 3 else None
st = np.load(d/"state.npz")
pos, box, cutoff = st["pos"], st["box"], float(st["cutoff"])
rd = lambda name, t: np.fromfile(d/name, dtype=t)
numAtoms, padded, maxBits, T = (int(v) for v in rd("meta.i32", np.int32)[:4])
numTiles = int(rd("count.u32", np.uint32)[0])
tiles = rd("tiles.i32", np.int32)[:numTiles]
atoms = rd("atoms.i32", np.int32)[:numTiles*T].reshape(numTiles, T)
order = rd("order.i32", np.int32)


def placed(p):
    P = np.zeros((padded, 3))
    P[:numAtoms] = p[order[:numAtoms]]
    return P


P0 = placed(pos)
P2 = None
if moves_path:
    mv = np.load(moves_path)
    # The recorded run starts up to 0.08 nm from the dumped state, so only its two-step displacement is used.
    P2 = placed(pos+mv["moves"][1].astype(np.float64))


def d2(P, xi, yj):
    v = P[yj][:, None, :, :]-P[xi][:, :, None, :]
    v -= box*np.round(v/box)
    return (v*v).sum(-1)


def census(tl, al, cut, P2=None):
    """tl: x block per tile, al: (tiles, 32) y atoms (>= numAtoms is empty). Counts per 32x32 tile."""
    pc2, c2 = (1.08*cut)**2, cut*cut
    out = dict(tiles=len(tl), units=0, alive=0, alive_c0=0, alive_c2=0, useful0=0, useful2=0,
               ch4=0, ch4_empty=0, ch8=0, ch8_empty=0, ch4_empty_c0=0, ch8_empty_c0=0, ch4_pad=0, ch8_pad=0)
    for s in range(0, len(tl), 2048):
        xi = tl[s:s+2048, None]*T+np.arange(T)[None, :]
        yj = al[s:s+2048]
        valid = (xi < numAtoms)[:, :, None] & (yj < numAtoms)[:, None, :]
        yc = np.where(yj < numAtoms, yj, 0)
        r0 = d2(P0, xi, yc)
        hitp = valid & (r0 < pc2)
        hit0 = valid & (r0 < c2)
        n = len(xi)
        # (tile, x cluster 4 x 8, y quad 8 x 4)
        u = lambda h: h.reshape(n, 4, 8, 8, 4).any((2, 4))
        out["units"] += n*32
        out["alive"] += int(u(hitp).sum())
        out["alive_c0"] += int(u(hit0).sum())
        out["useful0"] += int(hit0.sum())
        if P2 is not None:
            hit2 = valid & (d2(P2, xi, yc) < c2)
            out["alive_c2"] += int(u(hit2).sum())
            out["useful2"] += int(hit2.sum())
        yp = hitp.any(1)
        y0 = hit0.any(1)
        for w in (4, 8):
            out[f"ch{w}"] += n*(T//w)
            out[f"ch{w}_empty"] += int((~yp.reshape(n, T//w, w).any(2)).sum())
            out[f"ch{w}_empty_c0"] += int((~y0.reshape(n, T//w, w).any(2)).sum())
            out[f"ch{w}_pad"] += int((yj >= numAtoms).reshape(n, T//w, w).all(2).sum())
    out["s"] = out["alive"]/out["units"]
    out["s_cut_age0"] = out["alive_c0"]/out["units"]
    if P2 is not None:
        out["s_cut_age2"] = out["alive_c2"]/out["units"]
    for w in (4, 8):
        out[f"empty{w}"] = out[f"ch{w}_empty"]/out[f"ch{w}"]
        out[f"empty{w}_cut"] = out[f"ch{w}_empty_c0"]/out[f"ch{w}"]
        out[f"empty{w}_all_padding"] = out[f"ch{w}_pad"]/out[f"ch{w}"]
        # Chunks of real atoms only: the rate a mask adds over simply stopping at the tile's last filled slot.
        out[f"empty{w}_real"] = (out[f"ch{w}_empty"]-out[f"ch{w}_pad"])/(out[f"ch{w}"]-out[f"ch{w}_pad"])
    # Instruction model per tile: base 1600, 8x4 masked units 960 s + 600 (consult, Q2 r1).
    out["base_instr_per_useful"] = 1600*out["tiles"]/out["useful0"]
    out["unit_instr_per_useful"] = (960*out["s"]+600)*out["tiles"]/out["useful0"]
    return out


def repack(cut, halves):
    """Keep the list's order; per x block (or x half-block) drop y atoms with no x atom inside cut*1.08, pack in 32s.
    A half-block list is expanded to 32x32 tiles whose other 16 x rows are empty, so the same unit census applies."""
    pc2 = (1.08*cut)**2
    tl, al = [], []
    groups = {}
    for s in range(0, numTiles, 2048):
        xi = tiles[s:s+2048, None]*T+np.arange(T)[None, :]
        yj = atoms[s:s+2048]
        valid = (xi < numAtoms)[:, :, None] & (yj < numAtoms)[:, None, :]
        hit = valid & (d2(P0, xi, np.where(yj < numAtoms, yj, 0)) < pc2)
        for k in range(len(xi)):
            parts = (hit[k, :16], hit[k, 16:]) if halves else (hit[k],)
            for h, hk in enumerate(parts):
                keep = yj[k][hk.any(0)]
                if len(keep):
                    groups.setdefault((int(tiles[s+k]), h), []).append(keep)
    for (x, h), lst in groups.items():
        y = np.concatenate(lst)
        for i in range(0, len(y), T):
            row = np.full(T, padded, np.int32)
            row[:len(y[i:i+T])] = y[i:i+T]
            tl.append((x, h))
            al.append(row)
    tl = np.array(tl)
    al = np.array(al)
    if not halves:
        return tl[:, 0], al
    # Half tile (x, h): mask the other half's x rows by pointing them past numAtoms is not possible with a block
    # index, so return the half index for the caller.
    return tl, al


res = {"dump": str(d), "cutoff": cutoff, "list_tiles": numTiles}
if cut_override is None:
    res["real"] = census(tiles, atoms, cutoff, P2)
    tl, al = repack(cutoff, False)
    res["repacked"] = census(tl, al, cutoff)
    ht, ha = repack(cutoff, True)
    # Half tiles: 16 x atoms by 32 y slots, 2 x clusters by 8 quads = 16 units. Census the full block and keep only
    # the units of the tile's own half.
    pc2 = (1.08*cutoff)**2
    alive = units = useful = 0
    for s in range(0, len(ht), 2048):
        x, h = ht[s:s+2048, 0], ht[s:s+2048, 1]
        xi = x[:, None]*T+np.arange(T)[None, :]
        yj = ha[s:s+2048]
        valid = (xi < numAtoms)[:, :, None] & (yj < numAtoms)[:, None, :]
        r = d2(P0, xi, np.where(yj < numAtoms, yj, 0))
        n = len(x)
        mine = (np.arange(T)[None, :]//16 == h[:, None])[:, :, None]
        hp = valid & mine & (r < pc2)
        alive += int(hp.reshape(n, 4, 8, 8, 4).any((2, 4)).sum())
        units += n*16
        useful += int((valid & mine & (r < cutoff**2)).sum())
    res["c16_half"] = dict(half_tiles=len(ht), units=units, alive=alive, s=alive/units, useful0=useful,
                           slots=len(ht)*512)
else:
    tl, al = repack(cut_override, False)
    res["cutoff"] = cut_override
    res["repacked"] = census(tl, al, cut_override)
print(json.dumps(res, indent=1))

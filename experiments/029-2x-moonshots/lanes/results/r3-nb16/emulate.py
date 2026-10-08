"""Count padded 16x32 packets on actual Metal list arrays, without constructing a new list.

Each x half gets its own compact y list across every ordinary tile for that x block.
The true cutoff is an optimistic fresh-list lower bound. The padded cutoff preserves
the current list's skin at construction. Exclusion/diagonal tiles and single pairs
stay on their existing paths. q includes padding to a full 32-receiver packet.
"""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np


def minimum_image(delta, box):
    """OpenMM reduced box convention: remove z, then y, then x images."""
    for axis in (2, 1, 0):
        delta -= np.floor(delta[..., axis:axis+1]/box[axis, axis]+0.5)*box[axis]
    return delta


def half_distances(positions, tiles, atoms, num_atoms, box=None):
    """Return minimum squared x-half to y distances; invalid atoms yield infinity."""
    x = tiles[:, None]*32+np.arange(32)
    valid_x = x < num_atoms
    valid_y = (atoms >= 0) & (atoms < num_atoms)
    delta = positions[np.minimum(x, num_atoms-1), None, :] - positions[np.clip(atoms, 0, num_atoms-1)][:, None, :, :]
    if box is not None:
        minimum_image(delta, box)
    squared = np.einsum("...i,...i->...", delta, delta)
    squared[~(valid_x[:, :, None] & valid_y[:, None, :])] = np.inf
    return squared.reshape(-1, 2, 16, 32).min(axis=2)


def analyze(data, chunk=256):
    meta = json.loads(str(data["metadata"]))
    n = meta["num_atoms"]
    positions = np.asarray(data["posq"][:, :3], dtype=np.float64)
    tiles = data["tiles"]
    atoms = data["atoms"]
    box = np.asarray(data["box"], dtype=np.float64) if meta["periodic"] else None
    if n <= 0 or positions.shape[0] < n or not np.isfinite(positions[:n]).all():
        raise ValueError("invalid positions")
    if atoms.shape != (len(tiles), 32) or np.any(tiles < 0) or np.any(tiles*32 >= n):
        raise ValueError("invalid tile arrays")
    if np.any(atoms < 0) or np.any(atoms > positions.shape[0]):
        raise ValueError("invalid receiver index")
    if box is not None and (np.any(np.diag(box) <= 0) or np.any(np.triu(box, 1))):
        raise ValueError("expected a reduced periodic box")
    radii = {"cutoff": meta["cutoff"], "padded": meta["padded_cutoff"]}
    if not 0 < radii["cutoff"] <= radii["padded"]:
        raise ValueError("invalid cutoff")
    counts = {name: np.zeros(((n+31)//32, 2), dtype=np.int64) for name in radii}
    local_packets = dict.fromkeys(radii, 0)
    real_y = 0
    for start in range(0, len(tiles), chunk):
        t, y = tiles[start:start+chunk], atoms[start:start+chunk]
        distance = half_distances(positions, t, y, n, box)
        real_y += int(np.count_nonzero(y < n))
        for name, radius in radii.items():
            survived = np.count_nonzero(distance < radius*radius, axis=2)
            np.add.at(counts[name], t, survived)
            local_packets[name] += int(np.count_nonzero(survived))
    old_slots = int(len(tiles))*1024
    # Exclusion tiles use a special diagonal loop; keep their count separate rather
    # than pretend that every exceptional tile costs the same as an ordinary tile.
    result = dict(test=meta["test"], precision=meta["precision"], step=meta["step"],
                  atoms=n, old_tiles=len(tiles), old_slots=old_slots, old_receivers=real_y,
                  unchanged_exclusion_tiles=len(data["exclusions"]), unchanged_single_pairs=len(data["singles"]))
    for name, count in counts.items():
        packets = int(((count+31)//32).sum())
        receivers = int(count.sum())
        result[name] = dict(receivers=receivers, packets=packets, slots=packets*512,
                            q=packets*512/old_slots if old_slots else None,
                            q_without_packet_padding=receivers*16/old_slots if old_slots else None,
                            q_without_cross_tile_compaction=local_packets[name]*512/old_slots if old_slots else None,
                            y_flush_ratio=packets/(len(tiles) or 1),
                            receiver_duplication=receivers/(real_y or 1))
    result["verdict"] = "PASS" if old_slots and result["padded"]["q"] <= 0.75 else "KILL"
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("snapshots", type=Path, nargs="+")
    parser.add_argument("--chunk", type=int, default=256)
    args = parser.parse_args()
    if args.chunk < 1:
        parser.error("chunk must be positive")
    for path in args.snapshots:
        with np.load(path, allow_pickle=False) as data:
            result = analyze(data, args.chunk)
        result["snapshot"] = path.name
        with path.open("rb") as stream:
            result["sha256"] = hashlib.file_digest(stream, "sha256").hexdigest()
        print(json.dumps(result, sort_keys=True), flush=True)


if __name__ == "__main__":
    main()

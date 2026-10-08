"""Materialize the CPU format for the fixed-coordinate force-loop kill test."""
import argparse
import json
from pathlib import Path

import numpy as np
from emulate import half_distances


def emit(data):
    meta = json.loads(str(data["metadata"]))
    n = meta["num_atoms"]
    pos = data["posq"][:, :3].astype(np.float64)
    tiles, atoms = data["tiles"], data["atoms"]
    box = data["box"] if meta["periodic"] else None
    groups = [[] for _ in range(2*((n+31)//32))]
    for start in range(0, len(tiles), 256):
        x, y = tiles[start:start+256], atoms[start:start+256]
        keep = half_distances(pos, x, y, n, box) < meta["padded_cutoff"]**2
        for i, block in enumerate(x):
            for half in range(2):
                selected = y[i, keep[i, half]]
                if len(selected):
                    groups[2*block+half].append(selected)
    half_ids, receivers = [], []
    for half, parts in enumerate(groups):
        if not parts:
            continue
        # Canonical order makes packet membership independent of list construction scheduling.
        y = np.sort(np.concatenate(parts))
        if np.any(y[1:] == y[:-1]):
            raise ValueError(f"duplicate receiver in x half {half}")
        packets = (len(y)+31)//32
        block = np.full(packets*32, len(data["posq"]), dtype=np.int32)
        block[:len(y)] = y
        half_ids.extend([half]*packets)
        receivers.append(block)
    return dict(tiles=np.array(half_ids, dtype=np.int32),
                atoms=np.concatenate(receivers) if receivers else np.empty(0, dtype=np.int32),
                counts=np.array([len(half_ids), len(data["singles"])], dtype=np.uint32))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("snapshot", type=Path)
    parser.add_argument("out", type=Path)
    args = parser.parse_args()
    with np.load(args.snapshot, allow_pickle=False) as data:
        result = emit(data)
        q = len(result["tiles"])/(2*len(data["tiles"]))
    np.savez_compressed(args.out, **result)
    print(json.dumps(dict(packets=len(result["tiles"]), q=q)), flush=True)


if __name__ == "__main__":
    main()

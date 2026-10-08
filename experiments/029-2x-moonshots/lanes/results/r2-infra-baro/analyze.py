"""Pressure statistics per (mode, platform, tree) from the stage jsonl files, and a permutation test of each
Metal group's y-axis mean against Reference. A run fails as the test would: any axis off 3 bar by more than 20%."""
import json
import sys
from collections import defaultdict

import numpy as np

groups = defaultdict(list)
for path in sys.argv[1:]:
    for line in open(path):
        if not line.startswith("{"):
            continue
        r = json.loads(line)
        if "pressure" in r and "race" not in r:
            groups[(r["mode"], r["platform"], r.get("tree", "integrated"))].append(r["pressure"])

rng = np.random.default_rng(0)
for key in sorted(groups):
    p = np.array(groups[key])
    failed = (np.abs(p - 3)/3 > 0.2).any(axis=1).mean()
    line = f"{' '.join(key):28s} n={len(p):3d} mean={np.round(p.mean(0), 3)} sd={np.round(p.std(0, ddof=1), 3)} " \
           f"y_median={np.median(p[:, 1]):.3f} failed={failed:.1%}"
    ref = groups.get((key[0], "Reference", "integrated"))
    if key[1] != "Reference" and ref:
        a, b = np.array(ref)[:, 1], p[:, 1]
        both, d = np.concatenate([a, b]), b.mean() - a.mean()
        perm = [rng.permutation(both) for _ in range(20000)]
        pval = np.mean([abs(x[len(a):].mean() - x[:len(a)].mean()) >= abs(d) for x in perm])
        line += f" y_minus_ref={d:+.3f} p={pval:.3f}"
    print(line)

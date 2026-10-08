"""Diagnose a failing md100 row from forces.py's .npz: is the max error a cutoff straddle?

For the atoms with the largest force error, lists every non-excluded partner within 1e-5 nm of
the cutoff with the analytic jump (cutoff_pairs.pair_amplitude) and each atom's residual after
removing it. CPU only.
usage: python diag.py <benchmarks dir> <test> <row.npz>...
"""
import os
import sys

import numpy as np

sys.path.insert(0, '/tmp/openmm-metal-bench/ultra-tools')
from cutoff_pairs import pair_amplitude  # noqa: E402
import openmm as mm  # noqa: E402
import openmm.unit as u  # noqa: E402

bench, test, paths = os.path.abspath(sys.argv[1]), sys.argv[2], sys.argv[3:]
os.chdir(bench)
source = open("benchmark.py").read()
exec(source[:source.index("def serializeTest")])
system, _, _ = retrieveTestSystem(test)
nb = next(f for f in system.getForces() if isinstance(f, mm.NonbondedForce))
cutoff = nb.getCutoffDistance().value_in_unit(u.nanometer)
box = np.diag(np.array([v.value_in_unit(u.nanometer) for v in system.getDefaultPeriodicBoxVectors()]))
exclusions = {tuple(sorted(nb.getExceptionParameters(k)[:2])) for k in range(nb.getNumExceptions())}
for path in paths:
    data = np.load(path)
    positions, error = data["positions"], data["metal"]-data["reference"]
    norms = np.linalg.norm(error, axis=1)
    order = np.argsort(-norms)
    print(f"{path}: max|dF| {np.abs(error).max():.4g}, top atom norms {', '.join(f'{norms[k]:.3g}' for k in order[:5])}, "
          f"median atom norm {np.median(norms):.3g}")
    for i in order[:5]:
        delta = positions-positions[i]
        delta -= box*np.round(delta/box)
        distances = np.linalg.norm(delta, axis=1)
        near = [j for j in np.flatnonzero(np.abs(distances-cutoff) <= 1e-5)
                if j != i and tuple(sorted((int(i), int(j)))) not in exclusions]
        print(f"  atom {i}: |err| {norms[i]:.4g}, partners within 1e-5 nm of cutoff: {len(near)}")
        for j in near:
            d = positions[j]-positions[i]
            d -= box*np.round(d/box)
            r = np.linalg.norm(d)
            jump = (-1 if r < cutoff else 1)*(-pair_amplitude(nb, int(i), int(j), min(r, cutoff), cutoff)*d/r)
            m = np.linalg.norm(jump)
            print(f"    j {j}: r-rc {r-cutoff:+.3e} nm, jump {m:.4g}, residual i {np.linalg.norm(error[i]-jump):.4g}, "
                  f"residual j {np.linalg.norm(error[j]+jump):.4g}, |err j| {norms[j]:.4g}")

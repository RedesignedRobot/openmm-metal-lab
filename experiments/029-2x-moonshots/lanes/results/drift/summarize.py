"""Drift table from dhfr-nve.py results: mean and standard error over runs for every result set, next to the
OpenMM 7 paper's CUDA numbers (Eastman et al. 2017, Table 5, Titan X Pascal, CUDA 7.5).

usage: python summarize.py <results dir>
Every subdirectory holding seed-*.json files is one set (diag/ is skipped). kT/ns/dof uses kT at 300 K and the dof
of this system (3N - constraints - 3); the paper's rows use the same system, so the same dof converts them.
Run time is wall seconds from Context creation to the last sample, summed over the sets' runs and diag/.
"""
import glob
import json
import os
import sys

import numpy as np

KT = 0.0083144626*300
PAPER = [("CUDA single (paper)", 1.557, 0.003), ("CUDA mixed (paper)", -0.0047, 0.0008),
         ("CUDA double (paper)", -0.0062, 0.0002)]

root = sys.argv[1]
rows, dof, metal_s, cpu_s = [], None, 0.0, 0.0
for setdir in sorted(glob.glob(os.path.join(root, "*", ""))):
    if os.path.basename(setdir.rstrip("/")) == "diag":
        for diag in glob.glob(os.path.join(setdir, "*.json")):
            run = json.load(open(diag))
            metal_s += run["wall_s"] if run["platform"] == "Metal" else 0.0
            cpu_s += run["wall_s"] if run["platform"] != "Metal" else 0.0
        continue
    runs = [json.load(open(p)) for p in sorted(glob.glob(os.path.join(setdir, "seed-*[0-9].json")))]
    if not runs:
        continue
    first = runs[0]
    drift = np.array([r["drift_kj_mol_ps"] for r in runs])
    dof = first["dof"]
    wall = sum(r["wall_s"] for r in runs)
    if first["platform"] == "Metal":
        metal_s += wall
    else:
        cpu_s += wall
    se = drift.std(ddof=1)/np.sqrt(len(drift)) if len(drift) > 1 else float("nan")
    label = (f"{first['openmm_lib'].split('/')[3]} {first['platform']} {first['precision']}, tol {first['constraint_tolerance']:g}, "
             f"ewald {first['ewald_error_tolerance']:g}{', LJ switch %g nm' % first['lj_switch_nm'] if first.get('lj_switch_nm') else ''}, "
             f"{first['nve_ns']:.2g} ns")
    rows.append((label, len(runs), drift.mean(), se))
    print(f"# {setdir}: {label}; seeds {[r['seed'] for r in runs]}; libOpenMM md5 "
          f"{sorted({r['libOpenMM_md5'] for r in runs})}; lib {sorted({r['openmm_lib'] for r in runs})}")
    print(f"#   per-run kJ/mol/ps: {' '.join(f'{d:+.4f}' for d in drift)}")
    print(f"#   median white-noise slope SE {np.median([r['se_white_kj_mol_ps'] for r in runs]):.4f}; "
          f"mean T {np.mean([r['temperature_mean_k'] for r in runs]):.1f} K; wall {wall/3600:.2f} h")
rows += [(name, 10, mean, se) for name, mean, se in PAPER]

print(f"# dof {dof}, kT {KT:.4f} kJ/mol; run wall time Metal {metal_s/3600:.2f} h, CPU {cpu_s/3600:.2f} h")
print("| Run set | Runs | Drift (kJ/mol/ps) | Drift (kT/ns/dof) |")
print("| --- | ---: | ---: | ---: |")
scale = 1000/KT/dof
for name, n, mean, se in rows:
    print(f"| {name} | {n} | {mean:+.4f} ± {se:.4f} | {mean*scale:+.2e} ± {se*scale:.1e} |")

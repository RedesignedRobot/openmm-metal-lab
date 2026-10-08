# Evidence for the #5397 drift reply (comment 5857684368)

Each row of the posted table traces to the seed JSONs below. Every JSON records platform, precision, constraint tolerance, ewaldErrorTolerance, PME alpha and grid (`pme_alpha_nx_ny_nz`), libOpenMM md5 and the per-run slope. `python summarize.py .` rebuilds the full table, including the context arms. All runs: ultra-r1 (8ae6cf17b, libOpenMM md5 1cc48a57), 20 ps LangevinMiddle, then 1 ns leapfrog Verlet NVE at 2 fs, no LJ switch. SE is stdev/sqrt(n) over runs.

| Posted row | Dir | Seeds | ewald (alpha /nm, grid) | Mean ± SE kJ/mol/ps | Posted as |
| --- | --- | --- | --- | ---: | ---: |
| Metal mixed, tol 1e-8, ewald 1e-5 | `mixed-tol1e-8-ewald1e-5/` | 86, 87, 101-108 | 1e-5 (3.655, 154^3) | -0.0005 ± 0.0007 | -0.0005 ± 0.0007 |
| Metal single, tol 1e-8, ewald 1e-5 | `single-tol1e-8-ewald1e-5/` | 111, 112, 116, 117 | 1e-5 (3.655, 154^3) | -0.0844 ± 0.0021 | -0.084 ± 0.002 |
| Metal mixed, tol 1e-8, ewald 5e-4 | `mixed-tol1e-8/` | 21-30 | 5e-4 (2.920, 56^3) | +0.0617 ± 0.0044 | +0.062 ± 0.004 |
| CPU, tol 1e-8, ewald 5e-4 | `cpu-tol1e-8-1ns/` | 71 | 5e-4 (2.920, 56^3) | +0.0450 | +0.045 |

Per-run slopes, kJ/mol/ps:
- mixed ewald 1e-5: +0.0004, -0.0026, -0.0021, -0.0027, +0.0019, +0.0012, +0.0033, -0.0008, -0.0032, -0.0007
- single ewald 1e-5: -0.0872, -0.0885, -0.0821, -0.0796
- mixed ewald 5e-4: +0.0552, +0.0756, +0.0792, +0.0454, +0.0519, +0.0377, +0.0671, +0.0637, +0.0772, +0.0637
- CPU ewald 5e-4: +0.0450 (20 chunks of 50 ps, checkpoint resume, off the lease)

The single ewald 1e-5 row stopped at n=4 (review ruling 2026-09-27). Seeds 113-115 and 118-120 were queued and killed before running.

The posted text's other claims:
- "a +0.06 floor that the CPU platform shows too" is rows 3 and 4.
- "With the default constraint tolerance of 1e-5, the constraint residual dominates on every platform" is `mixed/` (+0.2124 ± 0.0042, seeds 1-10), `single/` (+0.1145 ± 0.0058) and `cpu-tol1e-5/` (-0.1115 ± 0.0286, 3 x 150 ps).
- The CUDA rows are Eastman et al. 2017, Table 5.

# 028 final report

Experiment 028 optimized the Metal platform on the M3 Ultra from 2026-09-24 evening to 2026-09-25, with the M2 as the base-chip check. It started from base 6df2b8bcb (`metal-hipdelta-gbsa`). This file is the summary. `candidates.json` holds every candidate and its state, `DEAD-ENDS.md` lists what died and why, and the raw data is in `windows/` and `lanes/<area>-results/`. The run's ledger and per-area logs are in this repository's history at commit 31c615ad.

## What was built

The result was commit 7484d7bef: 57 commits over base, 72 files, +3147/-564.
- `platforms/metal`: 27 files, +989/-148.
- `platforms/common` and `openmmapi`: 8 files, +669/-413, all under `USE_METAL` or Metal-only paths.
- The rest is the AMOEBA, Drude and RPMD Metal platforms.

Merged, in merge order. Ratios are each change's confirm run against the tree just below it, M3 Ultra, host clock.

| Change | Commit | Where it paid |
|---|---|---|
| PME float-atomic spread on Apple9, fixed point on Apple8 and under DeterministicForces | 71a602b43 | pme and apoa1pme family |
| PME atom sort skipped on Metal | 17929e631 | pme family |
| Mixed SHAKE/SETTLE: df64 residuals, float corrections, df64 fast paths (g2) | 5cc0ba5af | mixed gbsa 1.096, rf 1.174, pme 1.117 |
| Fused LangevinMiddle kernel for mixed (f1) | cf1d7fc14 | mixed over g2: gbsa 1.139, rf 1.239, pme 1.146 |
| SIMD sortShortList2 (sort2) | ec464a484 | pme 1.088, dhfr 1.094 |
| Batch-4 tiles below 32 x cores blocks (tiles4) | 6d72c3ae9 | rf 1.169, pme 1.085, gbsa 1.040 |
| x-resident tile runs, per-tile fixed point (xres) | 761d5a666 | apoa1rf 1.060, cellulose 1.038 |
| AMOEBA, Drude, RPMD on Metal | 4ab189b29 | amoebagk 3.34x OpenCL; amoebapme 1.04x |
| AMOEBA PME real2-grid fix | bb813dadc | compile fix after 71a602b43 |
| Chunked atom-owner bonded above 10,000 terms | 1a29563d1 | apoa1 and cellulose +10.9 to 14.6% |
| D3: bonded and nonbonded in one concurrent encoder on force-only steps | 72af6f137 | gbsa and dhfr +3 to 4% |
| Wait-free list sizing with an 8-buffer in-flight cap (wfcap) | 8fd1e8671 | gbsa 1.047 (M2 1.033), rf 1.047 |
| Unrolled findBlocks mask (u8) | 480825042 | rf 1.066, apoa1rf 1.078 |
| Batch-4 cut raised to 64 blocks per core (cut) | 8fa089cee | apoa1rf 1.031, apoa1pme 1.023 |

Correctness: the full gate on 7484d7bef passed on the M3 Ultra (forces against Reference, 134 TestMetal tests). The M2 check passed (forces gate, A/B, no footprint growth). Owed: a DeterministicForces run on the tip (xres, D3 and bonded chunks change summation order).

## Measured results

Window 1 (int b69efb0fe against base 6df2b8bcb, dedicated GPU, 3 rounds of 30 s, host clock, 135 runs, 0 build overlaps; raw in `windows/w1/`):

| test | int/base single | int/base mixed | int single/OpenCL | int mixed/OpenCL single |
|---|---|---|---|---|
| gbsa | 1.002 | 1.093 | 1.092 | 0.797 |
| rf | 1.001 | 1.150 | 1.089 | 0.813 |
| pme | 1.167 | 1.260 | 1.194 | 0.963 |
| apoa1rf | 0.999 | 1.068 | 1.066 | 0.923 |
| apoa1pme | 1.189 | 1.229 | 1.268 | 1.133 |
| apoa1ljpme | 1.382 | 1.396 | 1.560 | 1.414 |
| amber20-dhfr | 1.181 | 1.282 | 1.197 | 0.940 |
| amber20-cellulose | 1.209 | 1.224 | 1.366 | 1.248 |
| amber20-stmv | 1.236 | 1.244 | 1.414 | 1.290 |

Window 2 (7484d7bef against 6df2b8bcb, M3 Ultra, dedicated GPU, 3 rounds of 30 s, benchmark.py host clock): 135 runs, no missing results, no build overlaps. Medians below were regenerated from `windows/w2/ab` and match the archived summary.

| Test | OpenCL single ns/day | Metal single ns/day | Metal mixed ns/day | single/OpenCL | mixed/OpenCL |
| --- | ---: | ---: | ---: | ---: | ---: |
| gbsa | 1136.41 | 1592.43 | 1235.30 | 1.401 | 1.087 |
| rf | 648.93 | 1211.09 | 1017.97 | 1.866 | 1.569 |
| pme | 520.96 | 893.68 | 780.29 | 1.715 | 1.498 |
| apoa1rf | 280.59 | 413.08 | 357.99 | 1.472 | 1.276 |
| apoa1pme | 181.00 | 301.83 | 270.13 | 1.668 | 1.492 |
| apoa1ljpme | 127.12 | 240.74 | 218.48 | 1.894 | 1.719 |
| amber20-dhfr | 562.00 | 936.64 | 802.97 | 1.667 | 1.429 |
| amber20-cellulose | 48.05 | 82.04 | 74.57 | 1.707 | 1.552 |
| amber20-stmv | 18.59 | 30.28 | 27.74 | 1.629 | 1.492 |

Raw results: `experiments/028-ultra-max/windows/w2/summary.txt`. CPU medians (host clock) are pme 44.58, apoa1pme 17.45 and amber20-dhfr 45.92 ns/day. These put Metal mixed at 17.50x, 15.48x and 17.49x CPU. The CPU dhfr rounds span 14.0%, so retain that spread with comparisons. CPU summary is `windows/w2/cpu-summary.txt`.

The separate rf aggregate diagnostic used 2x10 s and host wall time. Median total throughput in ns/day was 1184.39 (final, one process), 1495.27 (final, four), 696.56 (base, one), 1178.27 (base, four), and 1228.56 (OpenCL, four). The corresponding four-process common-span rates were 1492.59, 1178.23 and 1228.29 ns/day; minimum overlap was 99.50%. These are concurrent-throughput diagnostics, not single-simulation benchmark ratios. Raw data and the regenerated table are in `experiments/028-ultra-max/windows/w2-agg/agg.jsonl` and `summary.txt`.

M2, final tip against base 6df2b8bcb (2x15 s, host clock, 2026-09-25T10:08Z): single 1.107 (apoa1pme) to 1.165 (pme), mixed 1.145 (cellulose) to 1.310 (rf). No footprint growth.

## What died

The dead-ends table with numbers is `DEAD-ENDS.md`. The big ones: native or hidden-latency 64-bit atomics, force words, simdgroup_matrix distances, PME stream and tiled spreading, MPSGraph FFT, concurrent encoders with hazard tracking, Metal 4, persistent kernels, relaxed math, float kicks in mixed, and a 4x target.

## Strongest suggestion from each area

- atomics: replace 64-bit force atomics in computeNonbonded with per-threadgroup float force blocks and a fixed-order reduction. A plain read-modify-write is 6.8x cheaper than the emulated add. (029 bet 3a.)
- nonbonded: key 64-bit force-add work per chip. Removing x-side adds saves 9.9% of an apoa1rf force evaluation on the Ultra and 1.1% on the M2.
- nblist: land MAX_BITS 0 outside LJPME: +6.4 to 9.9% on five tests; it also cuts dhfr's list budget from 314 MB to about 36 MB.
- dispatch: one M2 check of k-step 029ec544c against wfcap (predicted +4% on M2 gbsa, from two sessions). (029 bet 1.)
- mixed: go after gbsa's SHAKE, starting with a census of f1. gbsa mixed is 0.81 of single. (029 bet 4.)
- workloads: two-pass multi-block reductions for the mixed minimizer, which takes 7.95 s for 200 iterations on apoa1pme against 1.04 s single and 7.50 s on the CPU.
- plugins: a static kernel check in gate.sh for `volatile` on by-value values and barriers in lane-dependent branches. Both passed every test; one cost 3x on amoebagk.
- profiler: bring the rf neighbor list to OpenCL's cost. Done by sort2, tiles4 and u8: findBlocks went from 139.7 to 65.5 us/step and the sort from 44.6 to 7.0, against OpenCL's 117.9 and 33.2.

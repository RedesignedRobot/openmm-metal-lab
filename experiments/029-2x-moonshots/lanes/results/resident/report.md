# Bet 1 verdict: DEAD

The measured prototype does not meet the required 10% single-precision gain on either chip. M3 Ultra: GBSA +4.38%, RF +1.17%. M2: GBSA +6.74%, RF -0.04%. M2 GBSA single's two round ratios were 1.064 to 1.071. Correctness passes, but M2 peak memory also violates the no-growth rule: GBSA single +1.227 MiB and RF single +1.102 MiB. Do not merge this experimental default.

The measured decomposition explains the result. K-step batching alone gives M2 GBSA single +6.83%. Adding GPU-conditional rebuild dispatch leaves it at +6.74% in the subsequent paired-baseline session. On the Ultra, indirect rebuild dispatch adds 3.4% to GBSA single over k-step in the same session and gives no RF gain. This implementation leaves host per-step command encoding in place, so these results do not establish a ceiling for a fully GPU-encoded integrator loop.

The implementation imports k-step commit 029ec544c with its prerequisite on frozen 7484d7bef, preserving the merged concurrent encoder. A GPU displacement reduction writes five indirect dispatch grids. Neighbor-list reuse skips key generation, both short-list sort kernels, box sorting and list construction. The existing force math and accumulation are unchanged. The host batches up to eight steps per commit in admitted wait-free contexts and reads the existing shared count buffer. Reorder and capacity-dependent paths still synchronize. An idle worker submits unfinished batches when the host stops encoding.

This is GPU-controlled rebuild dispatch plus host-encoded batching. It is not a fully GPU-encoded integrator loop. Defaults are compiled in: the indirect path queries Apple GPU family support and the system's atom-block count; there is no environment selector. Scratch allocation is four bytes per atom block plus 60 bytes, limited to 4,156 bytes by the 1,024-block admission bound. Existing full-list capacity admission remains unchanged.

The tested prototype build source hash is 41d64d9617fbe63bdf50f43946918e24bbe59eb9. The k-step-only build hash is 81b91e48bfe49e50092cb879758c3e2d1150e09a. Both full C++ builds passed. Their immutable snapshots and patches are under the bench directories named in the run log. No commits or pushes were made.

## Correctness

`gate.sh --quick` on `/tmp/openmm-metal-bench/ultra-m29-resident-prototype`:

```
PASS
```

Raw quick-gate directory: `/tmp/openmm-metal-bench/ultra-m29-resident-prototype/gate-20260926T181111Z`.

`forces.py --md 100` exited zero with all twelve verdict rows below. The tool has no aggregate PASS line.

```
gbsa            2489    single  1.955e-06  8.007e-03  6.804e-07  ok
gbsa            2489     mixed  1.317e-05  9.293e-02  5.858e-07  ok
rf             23558    single  1.066e-06  1.997e-02  2.980e-07  ok
rf             23558     mixed  2.086e-05  3.732e-01  4.157e-07  ok
pme            23558    single  1.386e-06  1.600e-02  1.359e-06  ok
pme            23558     mixed  1.956e-05  3.233e-01  1.410e-06  ok
apoa1rf        92224    single  1.576e-06  4.136e-02  1.910e-07  ok
apoa1rf        92224     mixed  5.306e-05  7.497e-01  2.464e-07  ok
apoa1pme       92224    single  5.253e-05  2.528e-01  8.896e-07  ok
apoa1pme       92224     mixed  7.406e-05  6.770e-01  8.975e-07  ok
apoa1ljpme     92224    single  5.252e-05  2.527e-01  9.288e-07  ok
apoa1ljpme     92224     mixed  7.425e-05  6.953e-01  8.879e-07  ok
```

Raw md100 output: `/tmp/openmm-metal-bench/ultra-m29-resident/forces-md100.out`.

`detforces.py`:

```
PASS
```

All twelve force rows are bitwise identical within a context, across contexts and across three fresh processes; max|dF| is zero. Energy bits differ, as recorded by the tool. Raw output: `/tmp/openmm-metal-bench/ultra-m29-resident/detforces.txt`.

The changed batching spec was run once:

```
1/1 Test #228: TestMetalCommandBatchingSingle ...   Passed    1.79 sec
100% tests passed out of 1
```

The full ctest suite remains the gate's responsibility and was not run here. No repository typecheck exists for these C++ changes; the successful full build is the compile check.

## Changed source and validation status

- `platforms/metal/include/MetalContext.h` and `platforms/metal/src/MetalContext.cpp`: optional indirect dispatch arguments in the existing kernel launcher.
- `platforms/metal/src/MetalNonbondedUtilities.cpp`: k-step batching, displacement reduction and conditional rebuild dispatch.
- `platforms/metal/src/MetalQueue.cpp`: k-step idle submission and queue accounting.
- The six additional changed source files are listed individually under Scope extensions.

All ten changed files match the tested prototype snapshot. `git diff --check` passes. The source remains uncommitted with the experiment enabled by its compiled device query, so the gate can test exactly the measured build. This is an experimental handoff, not a merge candidate. The full ctest gate has not yet run; it runs after this round ends.

## Measurements


Full prototype on M3 Ultra:

| Test | Precision | Metal ns/day | / ultra-int028 Metal | / ultra-int028 OpenCL single | Raw ab.sh outdir |
|---|---|---:|---:|---:|---|
| gbsa | single | 1694.049 | 1.0438 | 1.4721 | `/tmp/openmm-metal-bench/ultra-m29-resident/resident-screen-small` |
| gbsa | mixed | 1282.736 | 1.0294 | 1.1147 | `/tmp/openmm-metal-bench/ultra-m29-resident/resident-screen-small` |
| rf | single | 1227.050 | 1.0117 | 1.8377 | `/tmp/openmm-metal-bench/ultra-m29-resident/resident-screen-small` |
| rf | mixed | 1018.903 | 0.9941 | 1.5260 | `/tmp/openmm-metal-bench/ultra-m29-resident/resident-screen-small` |
| pme | single | 906.925 | 1.0049 | 1.7719 | `/tmp/openmm-metal-bench/ultra-m29-resident/resident-screen-control` |
| pme | mixed | 789.775 | 1.0025 | 1.5430 | `/tmp/openmm-metal-bench/ultra-m29-resident/resident-screen-control` |
| amber20-dhfr | single | 949.186 | 1.0155 | 1.6836 | `/tmp/openmm-metal-bench/ultra-m29-resident/resident-screen-control` |
| amber20-dhfr | mixed | 822.760 | 1.0078 | 1.4594 | `/tmp/openmm-metal-bench/ultra-m29-resident/resident-screen-control` |

Full prototype on M2:

M2 full prototype, 2x15 s. OpenCL ratios are derived from infra's separate 3x30 s frozen-baseline denominator.

| Test | Precision | Metal ns/day | / ultra-int028 Metal | / ultra-int028 OpenCL single (derived) | Raw M2 outdir |
|---|---|---:|---:|---:|---|
| gbsa | single | 484.834 | 1.0674 | 1.2955 | `~/lab/ultra-m2.noindex/checks/20260926T202041Z-7484d7bef` |
| gbsa | mixed | 410.080 | 1.0894 | 1.0923 | `~/lab/ultra-m2.noindex/checks/20260926T202041Z-7484d7bef` |
| rf | single | 291.620 | 0.9996 | 1.1529 | `~/lab/ultra-m2.noindex/checks/20260926T202041Z-7484d7bef` |
| rf | mixed | 230.207 | 0.9936 | 0.9083 | `~/lab/ultra-m2.noindex/checks/20260926T202041Z-7484d7bef` |
| pme | single | 238.981 | 0.9976 | 1.2267 | `~/lab/ultra-m2.noindex/checks/20260926T202041Z-7484d7bef` |
| pme | mixed | 195.083 | 0.9938 | 1.0026 | `~/lab/ultra-m2.noindex/checks/20260926T202041Z-7484d7bef` |
| amber20-dhfr | single | 248.111 | 0.9992 | 1.1953 | `~/lab/ultra-m2.noindex/checks/20260926T202041Z-7484d7bef` |
| amber20-dhfr | mixed | 200.379 | 0.9941 | 0.9681 | `~/lab/ultra-m2.noindex/checks/20260926T202041Z-7484d7bef` |

Denominator raw: `~/lab/ultra-m2.noindex/denominator-20260926T172150Z`. Infra verdict: `PASS 81/81 results wall=3799.1s`.

K-step in the same clean paired sessions:

| Test | Precision | Metal ns/day | / ultra-int028 Metal | / ultra-int028 OpenCL single | Raw ab.sh outdir |
|---|---|---:|---:|---:|---|
| gbsa | single | 1638.452 | 1.0095 | 1.4238 | `/tmp/openmm-metal-bench/ultra-m29-resident/resident-screen-small` |
| gbsa | mixed | 1253.564 | 1.0060 | 1.0893 | `/tmp/openmm-metal-bench/ultra-m29-resident/resident-screen-small` |
| rf | single | 1231.492 | 1.0153 | 1.8444 | `/tmp/openmm-metal-bench/ultra-m29-resident/resident-screen-small` |
| rf | mixed | 1030.834 | 1.0057 | 1.5439 | `/tmp/openmm-metal-bench/ultra-m29-resident/resident-screen-small` |
| pme | single | 907.473 | 1.0055 | 1.7730 | `/tmp/openmm-metal-bench/ultra-m29-resident/resident-screen-control` |
| pme | mixed | 794.585 | 1.0086 | 1.5524 | `/tmp/openmm-metal-bench/ultra-m29-resident/resident-screen-control` |
| amber20-dhfr | single | 958.084 | 1.0250 | 1.6994 | `/tmp/openmm-metal-bench/ultra-m29-resident/resident-screen-control` |
| amber20-dhfr | mixed | 822.957 | 1.0080 | 1.4597 | `/tmp/openmm-metal-bench/ultra-m29-resident/resident-screen-control` |

Original first k-step screen and M2 k-step screen:


All published speeds use benchmark.py host wall time. Screening uses two rounds of 15 seconds. The k-step Ultra screen had twelve build-overlap runs, marked in its summary; the full-prototype small-system screen had none. M2 OpenCL ratios are derived using infra's separately measured 3x30 s frozen-baseline denominator, per the review ruling, not a paired candidate/OpenCL session.

| Test | Precision | Metal ns/day | / ultra-int028 Metal | / ultra-int028 OpenCL single | Raw ab.sh outdir |
|---|---|---:|---:|---:|---|
| gbsa | single | 1620.193 | 1.0075 | 1.3731 | `/tmp/openmm-metal-bench/ultra-m29-resident/kstep-screen` |
| gbsa | mixed | 1246.504 | 1.0024 | 1.0564 | `/tmp/openmm-metal-bench/ultra-m29-resident/kstep-screen` |
| rf | single | 1223.406 | 0.9992 | 1.7155 | `/tmp/openmm-metal-bench/ultra-m29-resident/kstep-screen` |
| rf | mixed | 1021.127 | 1.0031 | 1.4318 | `/tmp/openmm-metal-bench/ultra-m29-resident/kstep-screen` |
| pme | single | 911.492 | 1.0059 | 1.7321 | `/tmp/openmm-metal-bench/ultra-m29-resident/kstep-screen` |
| pme | mixed | 793.177 | 1.0015 | 1.5073 | `/tmp/openmm-metal-bench/ultra-m29-resident/kstep-screen` |
| amber20-dhfr | single | 952.888 | 1.0056 | 1.6755 | `/tmp/openmm-metal-bench/ultra-m29-resident/kstep-screen` |
| amber20-dhfr | mixed | 815.174 | 1.0018 | 1.4334 | `/tmp/openmm-metal-bench/ultra-m29-resident/kstep-screen` |

M2 k-step, 2x15 s. OpenCL ratios derived from the independent infra 3x30 s denominator session, not a paired candidate/OpenCL session.

| Test | Precision | / ultra-int028 Metal | / ultra-int028 OpenCL single (derived) | Raw outdir |
|---|---|---:|---:|---|
| gbsa | single | 1.0683 | 1.2966 | `~/lab/ultra-m2.noindex/checks/20260926T190850Z-7484d7bef` |
| gbsa | mixed | 1.0884 | 1.0913 | `~/lab/ultra-m2.noindex/checks/20260926T190850Z-7484d7bef` |
| rf | single | 0.9954 | 1.1480 | `~/lab/ultra-m2.noindex/checks/20260926T190850Z-7484d7bef` |
| rf | mixed | 0.9987 | 0.9129 | `~/lab/ultra-m2.noindex/checks/20260926T190850Z-7484d7bef` |
| pme | single | 0.9989 | 1.2283 | `~/lab/ultra-m2.noindex/checks/20260926T190850Z-7484d7bef` |
| pme | mixed | 1.0033 | 1.0121 | `~/lab/ultra-m2.noindex/checks/20260926T190850Z-7484d7bef` |
| amber20-dhfr | single | 1.0014 | 1.1979 | `~/lab/ultra-m2.noindex/checks/20260926T190850Z-7484d7bef` |
| amber20-dhfr | mixed | 1.0017 | 0.9755 | `~/lab/ultra-m2.noindex/checks/20260926T190850Z-7484d7bef` |

Denominator raw: `~/lab/ultra-m2.noindex/denominator-20260926T172150Z`. Infra verdict: `PASS 81/81 results wall=3799.1s`.

## Memory, limits and recommendation

M2 peak footprint is the median of `/usr/bin/time -l` peak footprint across two rounds. Raw files are in `~/lab/ultra-m2.noindex/checks/20260926T202041Z-7484d7bef`, copied locally under `m2-prototype-results`.

| Test | Precision | Baseline peak MiB | Prototype peak MiB | Change MiB |
|---|---|---:|---:|---:|
| gbsa | single | 67.063 | 68.290 | +1.227 |
| gbsa | mixed | 70.274 | 70.188 | -0.086 |
| rf | single | 118.126 | 119.227 | +1.102 |
| rf | mixed | 122.712 | 123.516 | +0.805 |
| pme | single | 123.126 | 121.954 | -1.172 |
| pme | mixed | 128.352 | 128.251 | -0.102 |
| amber20-dhfr | single | 136.931 | 137.423 | +0.492 |
| amber20-dhfr | mixed | 145.923 | 146.204 | +0.281 |

The standard M2 tool printed:

```
verdict cand-src-eeb37082c7 7484d7bef401 PASS: gate PASS; slower: none; footprint growth: none; missing: none
CHECK WALL 578 s; tests=gbsa,rf,pme,amber20-dhfr; rounds=2; seconds=15
```

That tool's footprint flag is more permissive than the strict no-growth rule. The exact footprint table above governs the recommendation. All 32 M2 runs completed with zero build overlap and zero high-Spotlight starts. The M2 build matched source hash 41d64d9617fbe63bdf50f43946918e24bbe59eb9, and its force gate passed in 20 seconds.

All full-prototype Ultra runs also completed with zero build overlap. DHFR and OpenCL round spreads are recorded in the raw summaries, so subpercent differences are screening observations. The target gains remain below 10% on both chips. No 3x30 s confirmation was launched because the prototype failed the alive screen and is not a merge candidate. The requested 16/32-buffer variants were inspected but not benchmarked or folded in; their value remains unmeasured in this combination.

No outstanding child job remains. One queued correctness launcher was administratively cancelled before it ran so the remaining checks could share one lease; the preserved queue log and lane.md explain its nonzero exit. No GPU/test failure was hidden or retried. No full ctest was run here.

Strongest suggestion: do not merge this prototype. Preserve the negative result. A further Bet 1 attempt needs a concrete design for GPU-controlled integrator and RNG state plus whole-batch command encoding, coordinated with the integrator experiment. The tested conditional rebuild dispatch and k-step boundary change do not supply the required gain.

## Scope extensions

- `platforms/metal/include/MetalQueue.h`: idle worker lifetime, locking and commit counters for k-step batching.
- `platforms/metal/include/MetalNonbondedUtilities.h`: k-step accounting and indirect rebuild state.
- `platforms/metal/include/MetalSort.h`: declare indirect dispatch for the existing short-list sort.
- `platforms/metal/src/MetalSort.cpp`: dispatch existing sort kernels using GPU-written grids.
- `platforms/metal/src/kernels/findInteractingBlocks.metal`: displacement reduction, dispatch grids and rebuild bookkeeping without force-math changes.
- `platforms/metal/tests/TestMetalCommandBatching.cpp`: regression for automatic completion and bitwise equivalence to synchronized steps.
- `/tmp/openmm-metal-bench/ultra-m29-resident/report.md`: reviewable outcome and acceptance evidence.
- `/tmp/openmm-metal-bench/ultra-m29-resident/ready-run.sh`: serialize work after readiness and completed builds.
- `/tmp/openmm-metal-bench/ultra-m29-resident/screen-kstep.sh`: fixed k-step comparison.
- `/tmp/openmm-metal-bench/ultra-m29-resident/smoke-kstep.sh`: validate all screen configurations.
- `/tmp/openmm-metal-bench/ultra-m29-resident/smoke.py`: finite-energy one-step checks.
- `/tmp/openmm-metal-bench/ultra-m29-resident/report-ratios.py`: validate complete rounds and render ratios.
- `/tmp/openmm-metal-bench/ultra-m29-resident/recorded-pids.txt`: record ownership of detached jobs.
- `/tmp/openmm-metal-bench/ultra-m29-resident/kstep.patch`: preserve the k-step-only experiment.
- `/tmp/openmm-metal-bench/ultra-m29-resident/resident-prototype.patch`: preserve the full prototype.
- `/tmp/openmm-metal-bench/ultra-m29-resident/kstep-source/.commit`: identify the frozen M2 transfer snapshot.
- `/tmp/openmm-metal-bench/ultra-m29-resident/prototype-checks.sh`: bundle smoke, batching regression, md100 and determinism under one lease.
- `/tmp/openmm-metal-bench/ultra-m29-resident/run-prototype-rest.sh`: resume remaining checks and fixed screens after queue consolidation.

Build copies, tables and raw tool outputs are generated evidence. The superseded run-kstep.sh was removed before launch. The repository has no .codegraph index, so source investigation used targeted rg and file reads.

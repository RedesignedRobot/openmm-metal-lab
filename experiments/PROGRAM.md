# Program: performance, accuracy, compatibility (from 2026-09-23)

State file for the experiment program. Each lane lists its ranked experiments; status moves
queued -> running -> measured -> verified. A gain counts only with an end-to-end measurement that
names its clock and a fresh-context verifier pass.

Machines: Studio (M3 Ultra, main box for tests and timing since 2026-09-23, only under /tmp/openmm-metal-bench,
everything deleted when the work is done) and mini (M2, `amir@100.80.58.31` over Tailscale). The laptop (M3 Pro) is the owner's working machine: edit code there, but no builds,
GPU runs or timings (owner, 2026-09-23). M3 results come from the Studio. One heavy job per machine: every build, GPU run or timed measurement
holds that machine's lease, `mkdir /tmp/openmm-lease` (owner line inside; released right after; never
held while editing; stale after 60 min = ask the lead).
OpenMM's setup.py deletes whatever `openmm` its Python can import, even for `setup.py build` (removePackage).
Build a variant's Python module with an interpreter that has no openmm installed, never the Studio's shared
env: on 2026-09-23 a 022 variant build wiped the shared install, which was restored with
`ninja -C src/build PythonInstall` (restore-env.sh).
Harnesses that keep a program off FAH servers must fail closed: the FAH client fetches api.foldingathome.org/gpus
whenever its working directory lacks a fresh gpus.json, whatever --api-server says (023 rerun, 2026-09-23).

## Compatibility (research report 2026-09-23)

FAH on Apple GPUs needs: (1) Metal upstream in OpenMM (ours); (2) client detection of non-PCI GPUs,
fah-client-bastet#303, GPUResources.cpp drops non-PCI devices, 16-bit IDs (FAH's); (3) a new signed
macOS arm64 core that loads Metal (FAH core devs, closed source; "no plans" as of 2025-11);
(4) project constraints accepting Apple GPUs. Double precision: decline, as OpenCL does.

| # | Experiment | Status |
|---|---|---|
| C1 | Accept DeviceIndex ("0"), DisablePmeStream, DeterministicForces as validated properties (a FAH core passes them; today "Illegal property name") | verified (metal-fah-readiness rebased onto `metal` 052eaa85b 2026-09-24: 664adfdc0, ab6d6bb48, 0c69ccfe1, clean; M3 Ultra ctest -j4 109/112: the 2 LocalEnergyMinimizer are #5434, TestMetalConstantPotentialForceSingle failed once at TestConstantPotentialForce.h:1107 then passed 25 of 25, 5 alone and 20 as 4 concurrent copies; old head kept as metal-fah-readiness-pre-rebase) |
| C2 | Mock FAH core loop: XML WU -> Metal mixed -> checkpointState.xml -> reload, bitwise continuity, FAH state tests vs Reference (dhfr, nav, TIP4P-Ew, >1M atoms) | measured (exp 020): 4/5 WUs pass; stmv misses dPE 10 on Metal (15.5) and OpenCL single (18.9) alike, direct space, mechanism open |
| C3 | df64 sin/cos/pow/atan2/erf (QTB and CustomIntegrator in mixed) | queued |
| C4 | Mixed minimizer two-pass reduction (nav mixed 264 s -> target <100 s on M2) | queued |
| C5 | 31 buffer-slot limit: pack scalar args / argument buffers (CustomNonbonded >12 params, HIPPO 33 slots) | queued |
| C6 | Drude and RPMD Metal plugins (thin glue, port OpenCL tests) | queued |
| C7 | AMOEBA/HIPPO plugin (PRIVATE sweep + glue; after C5) | queued |
| C8 | Packaging: conda-forge osx-arm64 toolchain, runtime gate on older macOS | queued |
| C9 | Exp 024: Metal as the smallest diff from HIP (peastman plans his own Metal port from HIP, 2026-09-23 #5397). Metric: added lines vs a renamed HIP copy (baseline ~2,024 + df64 683). Stages: host, kernels via macros, then measured speedups, then df64 | stages 1-4 done, verified through stage 2 (mini metal-hipdelta 9074c38f1): 479 added lines + 589 df64, 110/110 Single+Mixed on M2 and M3 Ultra, M2 1.00 to 1.18x `metal`; M3 Ultra gbsa 0.86 to 0.93x (neighbor list build, open); stage 4 verified 2026-09-24 by verify-024s4 on the M2 (Metal ctest 109/110 then 5/5 on the stochastic Brownian test, same on `metal`; OpenCL ctest identical status to the merge base on all 191 tests, 66/66 Single; common code reviewed; range fix has no cross-threadgroup read left; df64 minimizer 1.17e-6 vs Reference). Notes for a PR: doubleToString virtual changes ComputeContext's vtable (plugins rebuild); OpenCL devices with fp64 but no int64 atomics now run mixed minimization instead of throwing; Metal mixed minimization 4x slower than single (one-threadgroup reductions, = C4) |

Maintainer questions (jcoffland, FAH core devs, peastman) are in the report; not sent (outreach paused).

## peastman on #5397, 2026-09-24 15:28Z

"Let's focus on the benchmark.py benchmarks ... A 40% speedup is worth doing a lot of work for. An 8% speedup isn't." (Earlier, 23 Sep 19:17Z: AI-generated code can't be used directly, only as a reference.) Owner's choice: measure first, then reply. Running: fah-precision (does FAH need mixed precision, which Apple OpenCL can't do) and best-metal (metal-hipdelta-fast = 6df2b8bcb + P0 simd_ballot, then benchmark.py vs OpenCL from the same tree on the M2, exp 025). M3 Ultra timings wait until the owner's 18 agents on the Studio are done. Gate notes: 6df2b8bcb M2 ctest 109/110 (TestMetalLangevinIntegratorMixed, rerun pending), Studio 109/110 (FlexibleBarostatMixed, rerun pending; /tmp/openmm-metal-bench/evwait kept for it).

## Resumed 2026-09-24 09:17 UTC

- GitHub: no new activity on #5397, cbang#213, #455, #303 at 09:17 UTC. Session cron polls every 2 hours (read only).
- gbsa gap closed on the M3 Ultra (gbsa-gap, then the lead after the agent ended with the session restart): the 0.85x was a 40 us GPU idle gap per step while the host blocked in waitUntilCompleted(); waiting on the shared event (waitUntilSignaledValue) removes it without a busy core. 6df2b8bcb on metal-hipdelta-gbsa (mini remote): 0.995 to 1.120x `metal` on all six tests, forces unchanged. M2 gates and M3 Ultra ctest running at 15:45Z. `metal` itself gains 1 to 2 percent from the same change (not applied).
- Lesson 2026-09-24: a remote command chain joined with `;` ran final.sh after a failed archive transfer, on the old tree. Chain transfer, verify and run with `&&`, and check a hash of the changed file on the remote before a gate.
- Lesson 2026-09-24: 024 and 025 launched mini jobs from zsh over ssh, so zsh's BG_NICE ran them at nice 5. 017's bench.sh guarded against this; the later scripts didn't. On macOS, `renice 0` needs root once a process is niced, so a niced timing run can only be killed and restarted. Launch with `setopt no_bg_nice` or through `/bin/sh -c`, and have every timing script refuse to run when `ps -o nice= -p $$` isn't 0.
- verify-024s4 finished 09:59 UTC: stage 4 verified (C9 row). Earlier running: gbsa-gap (per-kernel GPU profile on the M3 Ultra, owner at the machine).
- ConstantPotential flake closed (cp-flake, M2, 2026-09-24): upstream test fragility, not a Metal bug. Full test 1 fail in 480 runs (mixed alone), no concurrency effect. In-process probe: 6 of 9,235 Metal method-trials and 6 of 8,625 CPU-platform trials had exactly one electrode charge bitwise unchanged, never more than one. Seed 1312 (cg) leaves atom 230 unchanged in 20 of 20 replays; its true change is 1.34e-8 (Reference, double), about 29 float ulps, below the float solver noise. Metal runs the common kernels unchanged. Candidate upstream test fix: count unchanged electrode charges and assert <= 3 (a stale solve gives 300); 0 of 17,860 trials would fail it. Assertion from #4870.
- Upstream bug found by cp-flake, confirmed by the lead on origin/master: ComputeContext.cpp:48 does `workThread = new WorkThread()` and ~ComputeContext() is empty; no platform deletes it. Each Context leaks one thread (CPU platform about 2); a probe died after about 2,036 Contexts at kern.num_taskthreads 2048. No upstream issue found. Fix needs care: deleting in the base destructor runs after the derived context is gone, so a queued task could touch freed state; flush and delete at the start of each platform destructor or in a base cleanup the derived destructors call. Posted as openmm/openmm#5436 (2026-09-24, owner approved): one-line `delete workThread;`, a regression from #4833 (8.3.0 through 8.6.1). OpenCL 3,000-Context probe: 2,034 then crash before, 7 to 11 threads after.

## Paused 2026-09-24 ~08:20 UTC (owner offline). Resume here.

- Upstream: #5435 merged 2026-09-24 02:46Z (#5434 closed). #5397: my FAHBench-vs-benchmark.py answer and test offer posted 05:23Z, awaiting peastman. cbang#213, fah-client-bastet#455 and the #303 comment posted 2026-09-23 20:42Z, no replies yet. Public text is first person singular.
- `metal` (laptop, local only) is at 052eaa85b = P2 CCMA pipelining + P3 energy guard (exp 022, verified; ctest parity with base).
- No agents or background jobs running. Studio keeps only env/prefix/src/bin and rebuild scripts under /tmp/openmm-metal-bench (1.0 GB, owner's choice). Leases free.
- Next: (1) fresh verifier on 024 stage 4 and its 6 common-code files, including OpenCL ctest; (2) profile the M3 Ultra gbsa neighbor-list gap; decide on HIP's numTilesInBatch line; (3) rebase metal-fah-readiness onto `metal`; (4) poll #5397, cbang#213, #455, #303 (read only, show replies to the owner); (5) final cleanup of laptop scratch worktrees and mini ~/lab/hipdelta* when 024 is closed.
- Agent monitors missed job completion twice on 2026-09-23/24; the lead should poll lease and process state directly rather than trust an agent's monitor.

## Performance

| # | Experiment | Status |
|---|---|---|
| P0 | simd_ballot findInteractingBlocks in the platform (branch metal-simd-findblocks, exp 019) | measured (M2, host clock, median of 3 interleaved rounds): benchmark.py 1.058-1.257x (apoa1rf single 58.83 -> 73.98 ns/day), FAH WUs 1.021-1.098x; ctest 110/110; forces 5e-9 rel. Commit 33728aa53. Verified (verify-019: numbers recomputed from raw data, kernel faithful to CUDA, no races). Gain scales with rebuild rate: quote the FAH row (2 fs) for production. Next: M3 Ultra run; centre positions on block X for far-from-origin non-periodic systems |
| P1 | Instrumentation behind OPENMM_METAL_PROFILE: sync census (commits, finish, event waits, CCMA iterations), GPU busy/bubbles via completion handlers, per-kernel GPU time in a buffer-per-dispatch mode; dhfr, nav, dhfr-implicit, single and mixed | running (Studio, perf-studio; branch metal-perf-profile 32d09490d) |
| P2 | CCMA without drains: encode block k+1 before waiting on block k, read the flag from shared memory (bitwise identical; dhfr 1.1-1.6x est.). CCMA is the only place Metal leads OpenCL: FAHBench dhfr sends 3,072 constraints to CCMA (all bonds + H-X-H angles; every non-water constraint) and leads 1.20-1.28x; benchmark.py's dhfr (HBonds, 790 SHAKE clusters, 0 CCMA) ties. Also A/B Metal vs OpenCL CCMA alone to find why | running (Studio; branch metal-perf-sync bbf599ddc, laptop ctest 107/110 = #5434 x2 + 1 stochastic) |
| P3 | Attribute and fix the mixed-precision cost. Laptop census (indicative): computeNonbonded +39-40% in mixed (56% of nav's penalty) because force-only steps still accumulate df64 energy; SETTLE/SHAKE 4-7x, integrator 2-3x, CCMA 2x | running (Studio; branch metal-perf-p3-energy-guard 5f30ddc82). Next steps ranked in research/2026-09-23-mixed-without-fp64.md (estimates from the 022 census, untimed): energy guard, then CCMA with float inner math and df64 posDelta, then SHAKE/SETTLE float iteration (gate position SETTLE on water-box NVE). Reject float integrator kicks (1e-12 test) |
| P4 | Defer the neighbor-list count wait one step with rollback on overflow (upstream-relevant) | queued |
| P5 | Float-atomic PME spreading on Apple9+ only (~0.26 ms/step on Ultra; M2 slower) | queued |
| P6 | Native SIMD nonbonded (exp 010) on Apple9+ | queued |
| P7 | Per-chip grid and threadgroup sweep | queued |
| P8 | Relaxed math with df64 kept safe via `#pragma METAL fp math_mode(safe)` | queued |
| P9 | Overlap PME with nonbonded (concurrent encoder or second queue) | queued, needs P1 bubbles |
| P10 | Non-blocking uploads | queued, only if P1 shows per-step uploads |

The honest FAH bar: Metal MIXED vs OpenCL SINGLE (Apple OpenCL has no mixed). Host clock:
017 FAHBench 0.76-0.97x (dhfr-implicit 0.78-0.85, dhfr 0.80-0.97, nav 0.76-0.81); 018 benchmark.py
0.58-0.89x (worst rf 0.58 on M2, dhfr-sized systems 0.66-0.72). Metal single vs OpenCL single on 018: 0.99-1.07x.
Mixed cost vs Metal single: 15-42%, largest on the 23,558-atom dhfr systems (28-42%), smallest on cellulose/stmv. dhfr runs 1.28 ms/step on
both M3 Pro and M3 Ultra, so it's latency-bound (host syncs ~0.25 ms each). Rejected with evidence:
Metal 4 for dispatch cost, ICB replay (no setBytes), untracked hazards, simdgroup_matrix, MPSGraph FFT
(4-7x slower than VkFFT), MLX custom kernels, Metal 4 ML/tensors.

## Accuracy (research report 2026-09-23)

Forces are already deterministic (split-word Q32.32 fixed point; PME spreading always fixed point,
unlike CUDA's default). No Apple GPU through Apple9 has 64-bit atomic add (MSL 4.1: atomic_ulong
min/max only). Direct-space PME on every GPU platform uses the A&S erfc (coulombLennardJones.cc:12-20),
biased +3.2e-5 relative; Metal's own rational erfc (common.metal:112-118) is ~2000x better.
Double precision: decline.

| # | Experiment | Status |
|---|---|---|
| E4 | Root cause of M3 testLargeForces (#5434): float atomic rounding RNE vs RTZ probe, out-of-range float->long probe, M2 vs M3 | fixed and verified (Metal): on M3, float->signed int64 casts wrap mod 2^64 (M2 saturates), so realToFixedPoint turns 1e22+ forces into exactly 0 and L-BFGS exits at iteration 0. Independent probe (verify-e4) confirms on M3 Ultra + M2. Saturating realToFixedPoint + 5 direct-cast sites routed through it: branches metal-fixed-point-sat 556fbad21 (Metal ctest 110/110 on M3 Ultra) and opencl-fixed-point-sat 0e0a66cfe (upstream fix; TestOpenCLLocalEnergyMinimizer 3/3). Cost: noise (dhfr 1.001, nav 0.999). OpenCL side: upstream as openmm/openmm#5435, trimmed to the realToFixedPoint change in common.cl at peastman's request (9a824905b; OpenCL 66/66 on M3 Ultra); independent OpenCL probe on M3 Ultra confirms (021/verify-e4). Open: df64::operator long (df64.metal:455-458) still wraps; clamp it with the next Metal fix batch |

| E1 | Better erfc in direct-space PME via an upstream macro hook; host prediction first, then kernel A/B | queued |
| E2 | Replace 20-point fast-math probe with domain sweep (exp on [-88,0], log near 1, ulp not relative, NaN = fail); attribute Metal-vs-OpenCL energy gap | queued |
| E3 | Two-pass deterministic minimizer reductions (= C4) | queued |
| E5 | Per-dispatch GPU timestamps single vs mixed: where the 15-42% mixed cost goes | queued (shared with perf profiling) |
| E6 | Faster/tighter df64 add/mul where E5 says df64 is hot | blocked on E5 |
| E7 | Per-tile fixed-point energies: bitwise-reproducible energies | queued |
| E8 | Note on why no double mode | queued (docs) |

Validation protocol to adopt (P1-P6): User Guide 14 per-atom median force error per force type at
float-exact positions vs published CUDA; ubiquitin OBC NVE drift and OpenMM 7 DHFR drift protocol
(10 x 1 ns); bitwise reproducibility across 10 contexts; per-chip ulp tables.

Report now says Metal single ties OpenCL on benchmark.py and leads only where CCMA runs. Drift paragraph says the 0.1 ns runs measure protocol, not platform (no parity claim).
Run P2 before claiming anything about drift.

# Program: performance, accuracy, compatibility (from 2026-09-23)

State file for the experiment program. Each lane lists its ranked experiments; status moves
queued -> running -> measured -> verified. A gain counts only with an end-to-end measurement that
names its clock and a fresh-context verifier pass.

Machines: mini (M2, main test box, `amir@100.80.58.31` over Tailscale) and Studio (M3 Ultra, only under
/tmp/openmm-metal-bench). The laptop (M3 Pro) is the owner's working machine: edit code there, but no builds,
GPU runs or timings (owner, 2026-09-23). M3 results come from the Studio. One heavy job per machine: every build, GPU run or timed measurement
holds that machine's lease, `mkdir /tmp/openmm-lease` (owner line inside; released right after; never
held while editing; stale after 60 min = ask the lead).

## Compatibility (research report 2026-09-23)

FAH on Apple GPUs needs: (1) Metal upstream in OpenMM (ours); (2) client detection of non-PCI GPUs,
fah-client-bastet#303, GPUResources.cpp drops non-PCI devices, 16-bit IDs (FAH's); (3) a new signed
macOS arm64 core that loads Metal (FAH core devs, closed source; "no plans" as of 2025-11);
(4) project constraints accepting Apple GPUs. Double precision: decline, as OpenCL does.

| # | Experiment | Status |
|---|---|---|
| C1 | Accept DeviceIndex ("0"), DisablePmeStream, DeterministicForces as validated properties (a FAH core passes them; today "Illegal property name") | running (branch metal-fah-readiness; mini or Studio) |
| C2 | Mock FAH core loop: XML WU -> Metal mixed -> checkpointState.xml -> reload, bitwise continuity, FAH state tests vs Reference (dhfr, nav, TIP4P-Ew, >1M atoms) | running (exp 020; mini or Studio) |
| C3 | df64 sin/cos/pow/atan2/erf (QTB and CustomIntegrator in mixed) | queued |
| C4 | Mixed minimizer two-pass reduction (nav mixed 264 s -> target <100 s on M2) | queued |
| C5 | 31 buffer-slot limit: pack scalar args / argument buffers (CustomNonbonded >12 params, HIPPO 33 slots) | queued |
| C6 | Drude and RPMD Metal plugins (thin glue, port OpenCL tests) | queued |
| C7 | AMOEBA/HIPPO plugin (PRIVATE sweep + glue; after C5) | queued |
| C8 | Packaging: conda-forge osx-arm64 toolchain, runtime gate on older macOS | queued |

Maintainer questions (jcoffland, FAH core devs, peastman) are in the report; not sent (outreach paused).

## Performance

| # | Experiment | Status |
|---|---|---|
| P0 | simd_ballot findInteractingBlocks in the platform (branch metal-simd-findblocks, exp 019) | running (mini) |
| P1 | Instrumentation behind OPENMM_METAL_PROFILE: sync census (commits, finish, event waits, CCMA iterations), GPU busy/bubbles via completion handlers, per-kernel GPU time in a buffer-per-dispatch mode; dhfr, nav, dhfr-implicit, single and mixed | running (Studio, perf-studio; branch metal-perf-profile 32d09490d) |
| P2 | CCMA without drains: encode block k+1 before waiting on block k, read the flag from shared memory (bitwise identical; dhfr 1.1-1.6x est.). CCMA is the only place Metal leads OpenCL: FAHBench dhfr sends 3,072 constraints to CCMA (all bonds + H-X-H angles; every non-water constraint) and leads 1.20-1.28x; benchmark.py's dhfr (HBonds, 790 SHAKE clusters, 0 CCMA) ties. Also A/B Metal vs OpenCL CCMA alone to find why | running (Studio; branch metal-perf-sync bbf599ddc, laptop ctest 107/110 = #5434 x2 + 1 stochastic) |
| P3 | Attribute and fix the mixed-precision cost. Laptop census (indicative): computeNonbonded +39-40% in mixed (56% of nav's penalty) because force-only steps still accumulate df64 energy; SETTLE/SHAKE 4-7x, integrator 2-3x, CCMA 2x | running (Studio; branch metal-perf-p3-energy-guard 5f30ddc82) |
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
| E4 | Root cause of M3 testLargeForces (#5434): float atomic rounding RNE vs RTZ probe, out-of-range float->long probe, M2 vs M3 | running (M3 Ultra done; M2 fix probe on the mini) |
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

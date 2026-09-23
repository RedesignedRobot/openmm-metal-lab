# Program: performance, accuracy, compatibility (from 2026-09-23)

State file for the experiment program. Each lane lists its ranked experiments; status moves
queued -> running -> measured -> verified. A gain counts only with an end-to-end measurement that
names its clock and a fresh-context verifier pass.

Machines: mini (M2, main test box), laptop (M3 Pro, free after 018), Studio (M3 Ultra, final
benchmarks only, /tmp/openmm-metal-bench). One heavy job per machine.

## Compatibility (research report 2026-09-23)

FAH on Apple GPUs needs: (1) Metal upstream in OpenMM (ours); (2) client detection of non-PCI GPUs,
fah-client-bastet#303, GPUResources.cpp drops non-PCI devices, 16-bit IDs (FAH's); (3) a new signed
macOS arm64 core that loads Metal (FAH core devs, closed source; "no plans" as of 2025-11);
(4) project constraints accepting Apple GPUs. Double precision: decline, as OpenCL does.

| # | Experiment | Status |
|---|---|---|
| C1 | Accept DeviceIndex ("0"), DisablePmeStream, DeterministicForces as validated properties (a FAH core passes them; today "Illegal property name") | running (laptop, branch metal-fah-readiness) |
| C2 | Mock FAH core loop: XML WU -> Metal mixed -> checkpointState.xml -> reload, bitwise continuity, FAH state tests vs Reference (dhfr, nav, TIP4P-Ew, >1M atoms) | running (laptop, exp 020) |
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

Research report pending.

## Accuracy (research report 2026-09-23)

Forces are already deterministic (split-word Q32.32 fixed point; PME spreading always fixed point,
unlike CUDA's default). No Apple GPU through Apple9 has 64-bit atomic add (MSL 4.1: atomic_ulong
min/max only). Direct-space PME on every GPU platform uses the A&S erfc (coulombLennardJones.cc:12-20),
biased +3.2e-5 relative; Metal's own rational erfc (common.metal:112-118) is ~2000x better.
Double precision: decline.

| # | Experiment | Status |
|---|---|---|
| E4 | Root cause of M3 testLargeForces (#5434): float atomic rounding RNE vs RTZ probe, out-of-range float->long probe, M2 vs M3 | queued (needs mini + laptop, minutes each) |
| E1 | Better erfc in direct-space PME via an upstream macro hook; host prediction first, then kernel A/B | queued |
| E2 | Replace 20-point fast-math probe with domain sweep (exp on [-88,0], log near 1, ulp not relative, NaN = fail); attribute Metal-vs-OpenCL energy gap | queued |
| E3 | Two-pass deterministic minimizer reductions (= C4) | queued |
| E5 | Per-dispatch GPU timestamps single vs mixed: where the 22-33% mixed cost goes | queued (shared with perf profiling) |
| E6 | Faster/tighter df64 add/mul where E5 says df64 is hot | blocked on E5 |
| E7 | Per-tile fixed-point energies: bitwise-reproducible energies | queued |
| E8 | Note on why no double mode | queued (docs) |

Validation protocol to adopt (P1-P6): User Guide 14 per-atom median force error per force type at
float-exact positions vs published CUDA; ubiquitin OBC NVE drift and OpenMM 7 DHFR drift protocol
(10 x 1 ns); bitwise reproducibility across 10 contexts; per-chip ulp tables.

REPORT FIX NEEDED: metal-report.html drift paragraph must not imply parity; absolute dhfr drift
(-110 to -177 kJ/mol/ns) is 25-35x OpenMM 7's published mixed value and CPU drifts as much here,
so it's protocol-limited. Reword at the next rebuild; claim nothing until P2 is run.

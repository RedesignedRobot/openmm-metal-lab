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
| C1 | Accept DeviceIndex ("0"), DisablePmeStream, DeterministicForces as validated properties (a FAH core passes them; today "Illegal property name") | queued |
| C2 | Mock FAH core loop: XML WU -> Metal mixed -> checkpointState.xml -> reload, bitwise continuity, FAH state tests vs Reference (dhfr, nav, TIP4P-Ew, >1M atoms) | queued |
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

## Accuracy

Research report pending.

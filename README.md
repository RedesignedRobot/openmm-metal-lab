# OpenMM Metal lab

Goal: help OpenMM get a native Metal platform, so Folding@home and every other OpenMM user can run molecular dynamics on Apple GPUs. The Mac mini (base M2, 8 GB, 10 GPU cores) is the dedicated test machine.

## Where upstream stands (openmm/openmm#5397, read 2026-09-21)

- peastman, the lead maintainer, set four conditions. The platform must build on Common Compute, because over 90% of the GPU code lives there. No Objective-C in the codebase: metal-cpp behind private C++17 files is the open route. NonbondedForce comes first, and it must beat the OpenCL platform or the work is not worth merging. CI needs a self-hosted Mac with a GPU, because GitHub's macOS runners have none.
- peastman's M4 Max profile of apoa1pme on OpenCL: computeNonbonded 33%, findBlocksWithInteractions 24%, gridSpreadCharge 14%, bonded 8%. His list of Metal wins: float atomics for gridSpreadCharge, SIMD shuffles for computeNonbonded, ballot and clz/ctz for findBlocksWithInteractions.
- philipturner wrote the earlier plugin (philipturner/openmm-metal, OpenCL kernels through cl2Metal, last push 2024-08). He measured 1.3x to 1.5x on apoa1rf from SIMD-scoped reductions and asked for profiles on older chips. Float atomics exist on M3 and later only.
- NORPG owns the active branch (NORPG/openmm `Objective-C`, head 8f6a7332, 2026-09-09). It implements ComputeContext, arrays, queues, events, programs and kernels in Objective-C++ with runtime MSL compilation. It does not run the Common kernel sources yet. Checked again 2026-09-21 evening: no new commits, and the thread's last comment is from 2026-09-15. The branch compiles as MSL 3.0; the program-scope builtins peastman proposed on 2026-09-14 need MSL 3.1 (experiment 007), worth telling NORPG.

## What this lab does

We complement NORPG, we do not race them. The lab produces evidence and code that nobody in the thread has yet:

1. Baselines on a base M2: OpenCL and CPU numbers for the standard benchmarks plus the per-kernel profile. philipturner asked for older-chip data.
2. The Common kernel census: how much of `platforms/common/src/kernels/*.cc` compiles as MSL behind a macro prelude, and what blocks the rest. This answers peastman's question "is MSL sufficiently similar".
3. After that, whatever the first two say is the bottleneck. Candidates: a metal-cpp port of NORPG's host layer, a Metal findBlocksWithInteractions with SIMD-group reductions, offering the mini as the self-hosted GPU runner.

## State on 2026-09-21

Done: 001 baseline, 002 Common kernel census (49 of 67, the rest are fragments), 003 M2 kernel profile, 004 probes, 005 real program census (26 of 26 ApoA1 programs build as Metal on both chips with two mechanical rewrites). Draft upstream comment in `drafts/`, waiting for the owner.

Owner ruling, 2026-09-21: the upstream post waits until this whole programme has run. Every claim gets tested by execution, no hypotheses left standing.

Programme, one experiment at a time on the mini:

- 006 numerical agreement: same program body through Apple's OpenCL and through Metal, identical inputs, element by element. Covers erf and erfc, an integrator, bonded forces. Running.
- 007 toolchain matrix: every MSL language version the runtime compiler accepts, fast math and math mode options, function constants against defines, runtime compile time per program, binary archives and pipeline caching, offline metallib where a toolchain exists. Output: which settings change results, which change speed.
- 008 host cost: dispatch latency and command buffer batching measured, classic command model against Metal 4, shared against private storage, metal-cpp against Objective-C call overhead, the GPU timestamp units the profile in 003 could not pin down.
- 009 neighbour list: findBlocksWithInteractions on the `simd_ballot` path against the OpenCL kernel, threadgroup size sweep, SIMD width checked on both chips.
- 010 computeNonbonded: needs 009's neighbour list. Numerical agreement first, then speed, with and without SIMD shuffles.
- 011 PME: gridSpreadCharge fixed point against float atomics with the real ApoA1 distribution, finishSpreadCharge cost, FFT candidates (VkFFT Metal, MPSGraph, Accelerate on unified memory). Done: on matched clocks PME ties with OpenCL, see experiments/011-pme/HEAD-NOTE.md.
- 012 sort and the remaining utilities. Done: tie with OpenCL, translated bucket sort kept, see experiments/012-sort-utilities/HEAD-NOTE.md.
- 013 the host layer decision, after asking NORPG. One Astra design lane.

## Rules

- Nothing goes to the upstream thread, and no pull request opens, without the owner reading it first.
- Every claim we post carries the chip, macOS version, OpenMM commit and the command that produced it.
- A result that says "Metal is not faster here" is a result. Report it.
- Two test chips: the mini (M2, the primary) and the head's Mac (M3 Ultra, for M3-family behaviour such as float atomics). Benchmarks never run while another job uses the same machine.

## Layout

- `mini.sh <tree> <cmd>` syncs a source tree to `~/lab/<name>` on the mini and runs a command there.
- `build-openmm.sh` and `bench.sh` run on the mini inside a synced tree.
- `experiments/NNN-name/` holds one experiment each: a README with the question, the method, the result and what it changes.
- `results/` holds raw benchmark JSON pulled from the mini.
- OpenMM fork: `~/code/openmm` (origin RedesignedRobot/openmm, remotes `upstream` and `norpg`).

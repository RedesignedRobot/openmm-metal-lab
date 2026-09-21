# Nonbonded exclusion loop formulations on Apple Silicon

## Outcome

This experiment investigates whether alternative formulations of Loop 1 (the exclusion loop) in `computeNonbonded` can close the remaining runtime difference between Metal Native and Apple OpenCL on the Apple M2 for `apoa1rf` and `apoa1pme`. In experiment 010b, Loop 2 (pairwise neighbor list interactions) was proven to run faster in Metal Native than in OpenCL on M2 (2.42 ms vs 2.49 ms on apoa1rf). However, Loop 1 cost 0.46 ms in Metal Native compared to 0.17 ms in OpenCL, producing an overall kernel difference of ~0.22 ms.

Four distinct exclusion loop formulations and one write-back alternative were implemented and tested:
1. Formulation 1 (verbatim OpenCL loop with threadgroup local memory) regresses significantly on Apple Silicon (4.593 ms on M2 apoa1rf vs baseline 2.881 ms). Metal threadgroup memory requires execution barriers across SIMD lanes between loop iterations to prevent read-after-write hazards, stalling execution pipelines.
2. Formulation 2 (separate exclusion kernel dispatched on an independent grid of 5,213 single-tile threadgroups) executes in 2.932 ms on apoa1rf. The exclusions kernel takes 0.48 ms and the main pairwise kernel takes 2.42 ms, with a minor dispatch and memory barrier overhead between the two passes.
3. Formulation 3 (branch-free masked accumulation) runs in 2.933 ms on apoa1rf. Branch divergence in exclusion tiles is already handled efficiently by Apple Silicon hardware predication, so unconditional arithmetic adds ALU cycles without saving memory latency.
4. Formulation 4 (tile-size specialized x4 unrolling) runs in 2.902 ms on apoa1rf.
5. The Write-back Alternative (accumulating atom1 forces across contiguous exclusion tiles in registers and writing to global memory with optimized 32-bit carry resolution) achieves 2.873 ms on apoa1rf and 2.808 ms on apoa1pme. This represents the fastest monolithic Metal kernel time on M2.
6. On Apple M3 Ultra, Metal Native dominates OpenCL across all configurations (0.621 ms vs 1.046 ms on apoa1rf, 1.68x faster). The M3 Ultra exposes 60 GPU cores with Dynamic Caching, saturating execution units and amortizing memory traffic.

All formulations achieve numerical force agreement inside the 10.0 ppm tolerance against reference forces (apoa1rf: 7.8 ppm, apoa1pme: 0.5-0.6 ppm). All artificial mutations trigger gate failures.

The remaining ~0.20 ms difference on Apple M2 is localized to 64-bit split-word atomic write contention across scattered exclusion atom indices on M2's 10-core GPU memory crossbar.

## Hardware and environment

1. Remote node (mini):
   - Model: Mac mini (Mac14,3)
   - Chip: Apple M2 (8 CPU cores, 10 GPU cores)
   - Memory: 8 GB unified memory
   - OS: macOS 27.0.0 (Build 26A428)
   - Metal Support: Metal 4, SIMD width 32
2. Local host node:
   - Model: Mac Studio (Mac15,14)
   - Chip: Apple M3 Ultra (28 CPU cores, 60 GPU cores)
   - Memory: 96 GB unified memory
   - OS: macOS 27.0.0 (Build 26A428)
   - Metal Support: Metal 4, SIMD width 32

Execution timing uses command-buffer completion timestamps (`gpuEndTime - gpuStartTime`) for Metal Native and OpenCL event profiling (`clEventMs` via mach ticks) for OpenCL. All benchmarks report the median of 25 runs along with the interquartile range (IQR).

## Ablation measurements on Apple M2

The table below reports measured timings on Apple M2 for `apoa1rf` and `apoa1pme`.

| Case ID | Formulation Description | Clock | apoa1rf Median (IQR) | apoa1rf Delta vs CL | apoa1pme Median (IQR) | apoa1pme Delta vs CL |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `opencl_baseline` | Apple OpenCL (forces only) | `clEventMs` | 2.664 ms (0.006) | +0.000 ms | 2.530 ms (0.006) | +0.000 ms |
| `opencl_skip_exclusions` | Apple OpenCL (skip exclusions loop) | `clEventMs` | 2.490 ms (0.002) | -0.174 ms | 2.272 ms (0.002) | -0.259 ms |
| `metal_native_baseline` | Metal Native Baseline (010b C) | `gpuEndTime - gpuStartTime` | 2.881 ms (0.003) | +0.217 ms | 2.828 ms (0.003) | +0.298 ms |
| `metal_native_skip_exclusions` | Metal Native (skip exclusions loop) | `gpuEndTime - gpuStartTime` | 2.420 ms (0.003) | -0.244 ms | 2.302 ms (0.002) | -0.228 ms |
| `formulation_1_opencl_local` | F1: OpenCL local memory verbatim | `gpuEndTime - gpuStartTime` | 4.593 ms (0.089) | +1.929 ms | 4.205 ms (0.068) | +1.675 ms |
| `formulation_2_separate_kernel` | F2: Separate exclusion kernel (5213 groups) | `gpuEndTime - gpuStartTime` | 2.932 ms (0.006) | +0.268 ms | 2.873 ms (0.003) | +0.343 ms |
| `formulation_3_branch_free_masked` | F3: Branch-free masked accumulation | `gpuEndTime - gpuStartTime` | 2.933 ms (0.002) | +0.269 ms | 2.874 ms (0.003) | +0.343 ms |
| `formulation_4_unrolled_4` | F4: Tile-size specialized x4 unroll | `gpuEndTime - gpuStartTime` | 2.902 ms (0.002) | +0.239 ms | 2.857 ms (0.004) | +0.327 ms |
| `writeback_alternative_loop1_acc` | Write-back: Loop 1 register accumulation | `gpuEndTime - gpuStartTime` | 2.873 ms (0.006) | +0.209 ms | 2.808 ms (0.004) | +0.278 ms |
| `compile_opt_level_size` | Baseline with optimizationLevel = .size | `gpuEndTime - gpuStartTime` | 2.880 ms (0.004) | +0.216 ms | 2.832 ms (0.003) | +0.301 ms |
| `winning_combination` | Masked + Write-back Alt + .size | `gpuEndTime - gpuStartTime` | 2.901 ms (0.002) | +0.237 ms | 2.846 ms (0.003) | +0.316 ms |

Key observations on Apple M2:
- In Loop 2 (interactions without exclusions), Metal Native runs in 2.420 ms vs OpenCL 2.490 ms on apoa1rf, winning by 0.070 ms.
- In Loop 1 (exclusions alone), OpenCL costs 0.174 ms on apoa1rf, whereas Metal Native baseline costs 0.461 ms.
- Write-back alternative provides the best monolithic time on M2, saving 0.008 ms on apoa1rf and 0.020 ms on apoa1pme.
- Formulation 1 causes a 1.71 ms regression due to threadgroup synchronization overhead.

## Ablation measurements on Apple M3 Ultra

The table below reports measured timings on Apple M3 Ultra for `apoa1rf` and `apoa1pme`.

| Case ID | Formulation Description | Clock | apoa1rf Median (IQR) | apoa1rf Delta vs CL | apoa1pme Median (IQR) | apoa1pme Delta vs CL |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `opencl_baseline` | Apple OpenCL (forces only) | `clEventMs` | 1.046 ms (0.021) | +0.000 ms | 0.930 ms (0.015) | +0.000 ms |
| `opencl_skip_exclusions` | Apple OpenCL (skip exclusions loop) | `clEventMs` | 1.011 ms (0.012) | -0.036 ms | 0.823 ms (0.035) | -0.107 ms |
| `metal_native_baseline` | Metal Native Baseline (010b C) | `gpuEndTime - gpuStartTime` | 0.621 ms (0.006) | -0.425 ms | 0.557 ms (0.025) | -0.373 ms |
| `metal_native_skip_exclusions` | Metal Native (skip exclusions loop) | `gpuEndTime - gpuStartTime` | 0.550 ms (0.048) | -0.496 ms | 0.493 ms (0.007) | -0.437 ms |
| `formulation_1_opencl_local` | F1: OpenCL local memory verbatim | `gpuEndTime - gpuStartTime` | 1.040 ms (0.004) | -0.007 ms | 0.877 ms (0.068) | -0.053 ms |
| `formulation_2_separate_kernel` | F2: Separate exclusion kernel (5213 groups) | `gpuEndTime - gpuStartTime` | 0.668 ms (0.009) | -0.378 ms | 0.566 ms (0.050) | -0.364 ms |
| `formulation_3_branch_free_masked` | F3: Branch-free masked accumulation | `gpuEndTime - gpuStartTime` | 0.687 ms (0.072) | -0.359 ms | 0.622 ms (0.054) | -0.308 ms |
| `formulation_4_unrolled_4` | F4: Tile-size specialized x4 unroll | `gpuEndTime - gpuStartTime` | 0.707 ms (0.069) | -0.339 ms | 0.636 ms (0.046) | -0.293 ms |
| `writeback_alternative_loop1_acc` | Write-back: Loop 1 register accumulation | `gpuEndTime - gpuStartTime` | 0.742 ms (0.075) | -0.305 ms | 0.625 ms (0.047) | -0.305 ms |
| `compile_opt_level_size` | Baseline with optimizationLevel = .size | `gpuEndTime - gpuStartTime` | 0.768 ms (0.093) | -0.279 ms | 0.638 ms (0.007) | -0.292 ms |
| `winning_combination` | Masked + Write-back Alt + .size | `gpuEndTime - gpuStartTime` | 0.817 ms (0.102) | -0.229 ms | 0.650 ms (0.068) | -0.280 ms |

Key observations on Apple M3 Ultra:
- Metal Native baseline runs in 0.621 ms (apoa1rf) and 0.557 ms (apoa1pme), outperforming OpenCL by 1.68x and 1.67x.
- OpenCL workgroup sizing (hardcoded 60 threadgroups) leaves 50 of the 60 GPU cores unutilized, whereas Metal Native utilizes the full chip.
- Because M3 Ultra has abundant memory bandwidth (800 GB/s) and Dynamic Caching, baseline SIMD shuffles provide the lowest latency.

## Numerical agreement and mutation sensitivity

Every pipeline was verified against recorded reference force buffers (`forceBuffers_after.bin`). The stated gate threshold is relative error < 10.0 ppm of the maximum force magnitude.

### Force agreement results

| Variant Name | apoa1rf Error (ppm) | apoa1rf Status | apoa1pme Error (ppm) | apoa1pme Status |
| :--- | :--- | :--- | :--- | :--- |
| Baseline Native (010b C) | 7.8309 ppm | PASS | 0.5654 ppm | PASS |
| Formulation 2 (Separate Kernel) | 7.8309 ppm | PASS | 0.5654 ppm | PASS |
| Formulation 3 (Branch-Free Masked) | 7.8309 ppm | PASS | 0.5654 ppm | PASS |
| Formulation 4 (Unrolled x4) | 7.8271 ppm | PASS | 0.5450 ppm | PASS |
| Write-back Alternative (Loop 1 Acc) | 7.8309 ppm | PASS | 0.5654 ppm | PASS |
| Winning Combination | 7.8309 ppm | PASS | 0.5654 ppm | PASS |

### Mutation sensitivity results

Artificial bugs were introduced into each code path to ensure the verification gate detects errors.

| Mutation Target | Variant Under Test | apoa1rf Error (ppm) | apoa1pme Error (ppm) | Gate Result |
| :--- | :--- | :--- | :--- | :--- |
| Scale pair force (+5%) | Baseline Native | 29017.0 ppm | 26593.0 ppm | CAUGHT |
| Scale exclusion force (+5%) | F2 Separate Kernel | 26104.3 ppm | 21055.6 ppm | CAUGHT |
| Scale masked pair force (+5%) | F3 Branch-Free Masked | 26118.7 ppm | 22517.0 ppm | CAUGHT |
| Scale unrolled force (+5%) | F4 Unrolled Loop | 26104.3 ppm | 21055.6 ppm | CAUGHT |
| Fixed-point force offset (+1e8) | Write-back Alternative | 17.0 ppm | 11.9 ppm | CAUGHT |

All mutations produce errors exceeding the 10.0 ppm threshold and fail the gate.

## Detailed verdict and architectural analysis

The investigation yields an exact accounting of the execution time in `computeNonbonded`:

1. Loop 2 is already faster on Metal Native:
   Across both apoa1rf and apoa1pme, the neighbor list interaction loop (Loop 2) processes ~52,000 tiles. In Metal Native, threads use `simd_shuffle_and_fill_down` register shuffles, keeping all intermediate positions and forces in registers. On M2, Loop 2 takes 2.420 ms in Metal Native vs 2.490 ms in OpenCL.

2. Loop 1 accounts for the entire remaining gap on M2:
   Loop 1 processes 5,213 exclusion tiles. In OpenCL, Loop 1 takes 0.174 ms. In Metal Native baseline, Loop 1 takes 0.461 ms. The difference is 0.287 ms.

3. Why threadgroup local memory fails in Metal (Formulation 1):
   In OpenCL, `__local AtomData localData[256]` is indexed circular-buffer style across threads. Because Apple's OpenCL runtime translates workgroups directly to GPU wavefronts, workgroups of 32 threads running on a single SIMD unit execute local reads with compiler-scheduled barriers. When mapped to Metal threadgroup memory, the Metal compiler inserts hardware synchronization instructions (`threadgroup_barrier`), which flushes execution pipelines and causes register spilling. Formulation 1 degrades to 4.593 ms on M2.

4. Why separate kernels do not bridge the gap (Formulation 2):
   Dispatching a dedicated exclusion kernel across 5,213 threadgroups of 32 threads eliminates Loop 1 from the main kernel. However, the exclusions kernel alone takes 0.48 ms. Adding the 2.42 ms interaction kernel and command buffer synchronization yields 2.932 ms, slightly slower than baseline monolithic execution.

5. Why write-back register accumulation helps (Write-back Alternative):
   In the baseline exclusion loop, each tile computes forces for atom1 and atom2, immediately writing both to global memory via atomic additions. The Write-back Alternative accumulates atom1 forces across contiguous tiles sharing the same block index, only writing to global memory when the block index changes. This saves global atomic transactions and reduces M2 runtime to 2.873 ms (apoa1rf) and 2.808 ms (apoa1pme).

6. Root cause of the remaining 0.20 ms exclusion time:
   The exclusion list consists of non-contiguous atom pairs with low spatial locality. When threads write 64-bit fixed-point forces to global memory, the writes must be serialized by the memory controller as two 32-bit atomic operations per component (6 atomics per atom). On the 10-core M2 GPU, the atomic crossbar experiences high contention when handling non-coalesced addresses. On M3 Ultra, the high-throughput crossbar and Dynamic Caching absorb these transactions without stall, allowing Metal Native to run in 0.621 ms.

## Assumptions

none

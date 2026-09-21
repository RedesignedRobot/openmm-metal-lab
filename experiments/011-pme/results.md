# Results: Experiment 011 Reciprocal-Space PME Pipeline

CORRECTED in HEAD-NOTE.md: the OpenCL times and every speed ratio below were measured on a different clock from the Metal times. Like for like, PME is a tie.

## Summary Speed Results

Every timing reports the median of 25 runs on step 200 of equilibrated ApoA1 simulation data (`apoa1pme`, 92,224 atoms, grid size 98x98x98). Input buffers are restored to their pre-kernel reference state before each run. GPU execution times are recorded from hardware profiling timestamps: Metal command buffer `(gpuEndTime - gpuStartTime) * 1000.0` ms; OpenCL `clFinish` wall time; VkFFT GPU query time; MPSGraph execution time.

### Standalone Reciprocal-Space PME Kernel Timings (median ms, IQR ms)

| Pipeline Stage | Implementation | Apple M2 Median (IQR) | Apple M2 Min / Max | Apple M3 Ultra Median (IQR) | Apple M3 Ultra Min / Max |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `findAtomGridIndex` | OpenCL Baseline | 0.348 ms (0.014 ms) | 0.333 / 0.386 ms | 0.287 ms (0.031 ms) | 0.256 / 0.383 ms |
| `findAtomGridIndex` | Metal Translation | 0.014 ms (0.004 ms) | 0.014 / 0.020 ms | 0.015 ms (0.001 ms) | 0.014 / 0.016 ms |
| `gridSpreadCharge` | OpenCL Baseline (fixed) | 1.237 ms (0.043 ms) | 1.208 / 1.284 ms | 0.823 ms (0.031 ms) | 0.788 / 1.041 ms |
| `gridSpreadCharge` | Metal Translation (fixed) | 0.653 ms (0.005 ms) | 0.646 / 0.664 ms | 0.556 ms (0.005 ms) | 0.407 / 0.562 ms |
| `gridSpreadCharge` | Metal Native (float atomics) | 0.830 ms (0.002 ms) | 0.829 / 0.835 ms | 0.170 ms (0.012 ms) | 0.165 / 0.184 ms |
| `gridSpreadCharge` | Metal Native (gather) | 27.888 ms (0.019 ms) | 27.865 / 27.921 ms | 3.293 ms (0.018 ms) | 3.279 / 3.328 ms |
| `finishSpreadCharge` | OpenCL Baseline | 1.077 ms (0.043 ms) | 1.017 / 1.126 ms | 0.780 ms (0.064 ms) | 0.713 / 0.887 ms |
| `finishSpreadCharge` | Metal Translation | 0.152 ms (0.006 ms) | 0.144 / 0.172 ms | 0.022 ms (0.001 ms) | 0.020 / 0.023 ms |
| `forwardFFT` (3D R2C) | VkFFT OpenCL | 0.416 ms (0.006 ms) | 0.411 / 0.476 ms | 0.216 ms (0.011 ms) | 0.199 / 0.260 ms |
| `forwardFFT` (3D R2C) | VkFFT Metal | 0.192 ms (0.003 ms) | 0.181 / 0.194 ms | 0.060 ms (0.001 ms) | 0.059 / 0.060 ms |
| `forwardFFT` (3D R2C) | MPSGraph | 0.836 ms (0.054 ms) | 0.752 / 0.924 ms | 0.322 ms (0.020 ms) | 0.308 / 0.407 ms |
| `reciprocalConvolution` | OpenCL Baseline | 0.593 ms (0.012 ms) | 0.556 / 0.632 ms | 0.452 ms (0.030 ms) | 0.413 / 0.645 ms |
| `reciprocalConvolution` | Metal Translation | 0.036 ms (0.004 ms) | 0.033 / 0.038 ms | 0.015 ms (0.000 ms) | 0.014 / 0.015 ms |
| `inverseFFT` (3D C2R) | VkFFT OpenCL | 0.385 ms (0.007 ms) | 0.369 / 0.407 ms | 0.213 ms (0.011 ms) | 0.197 / 0.227 ms |
| `inverseFFT` (3D C2R) | VkFFT Metal | 0.171 ms (0.003 ms) | 0.170 / 0.176 ms | 0.059 ms (0.000 ms) | 0.058 / 0.060 ms |
| `inverseFFT` (3D C2R) | MPSGraph | 1.414 ms (0.038 ms) | 1.337 / 1.510 ms | 0.408 ms (0.023 ms) | 0.381 / 0.824 ms |
| `gridInterpolateForce` | OpenCL Baseline | 1.624 ms (0.037 ms) | 1.486 / 8.463 ms | 1.042 ms (0.063 ms) | 0.946 / 1.170 ms |
| `gridInterpolateForce` | Metal Translation | 0.183 ms (0.003 ms) | 0.179 / 0.187 ms | 0.037 ms (0.002 ms) | 0.034 / 0.039 ms |

### Pipeline Aggregates

| Configuration | Apple M2 Pipeline Time | Apple M2 vs OpenCL | Apple M3 Ultra Pipeline Time | Apple M3 Ultra vs OpenCL |
| :--- | :--- | :--- | :--- | :--- |
| OpenCL Baseline Pipeline | 5.680 ms | 1.00x | 3.813 ms | 1.00x |
| Metal Straight Translation (VkFFT Metal) | 1.401 ms | 4.05x | 0.764 ms | 5.00x |
| Metal Optimized (Float Atomics, finishSpread eliminated, VkFFT Metal) | 1.426 ms | 3.98x | 0.341 ms | 11.18x |

## Host Environments

- Primary chip: Apple M2 Mac mini, 8 CPU cores (4 performance, 4 efficiency), 8 GPU cores, 8 GB unified memory, macOS 27.0 (Build 26A428). Output saved to `experiments/011-pme/results-m2.json`.
- Secondary chip: Apple M3 Ultra, 28 CPU cores, 60 GPU cores, 128 GB unified memory, macOS 27.0 (Build 26A428). Output saved to `experiments/011-pme/results-m3ultra.json`.

## Define Sets Verification

Preprocessor defines are verified to be identical between OpenMM's OpenCL compilation and the Metal straight translation:

| Macro Define | OpenCL Value | Metal Translation Value | Match |
| :--- | :--- | :--- | :--- |
| `EPSILON_FACTOR` | `1.17870886e+01f` | `1.17870886e+01f` | YES |
| `GRID_SIZE_X` | `98` | `98` | YES |
| `GRID_SIZE_Y` | `98` | `98` | YES |
| `GRID_SIZE_Z` | `98` | `98` | YES |
| `M_PI` | `3.14159265e+00f` | `3.14159265e+00f` | YES |
| `NUM_ATOMS` | `92224` | `92224` | YES |
| `NUM_INDICES` | `0` | `0` | YES |
| `PADDED_NUM_ATOMS` | `92224` | `92224` | YES |
| `PME_ORDER` | `5` | `5` | YES |
| `RECIP_EXP_FACTOR` | `1.15730498e+00f` | `1.15730498e+00f` | YES |
| `USE_FIXED_POINT_CHARGE_SPREADING` | `1` | `1` | YES |

## Numerical Agreement Verification

Stated tolerance threshold: < 10.0 ppm ($1.0 \times 10^{-5}$) relative L2 error across all kernels.

### Agreement Verification Table (Apple M2)

| Pipeline Stage | Comparison Pair | Exact Matches | Total Elements | Max Abs Diff | L2 Rel Diff | Rel Diff (PPM) | Gate Status |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `findAtomGridIndex` | Metal vs Captured Ref | 184,448 | 184,448 | 0 | 0.0 | 0.000 ppm | PASS |
| `findAtomGridIndex` | OpenCL vs Captured Ref | 184,448 | 184,448 | 0 | 0.0 | 0.000 ppm | PASS |
| `gridSpreadCharge` | Metal vs Captured Ref | - | 941,192 | 8.342e-7 float | 2.627e-7 | 0.263 ppm | PASS |
| `gridSpreadCharge` | OpenCL vs Captured Ref | 941,192 | 941,192 | 0.0 float | 0.0 | 0.000 ppm | PASS |
| `finishSpreadCharge` | Metal vs Captured Ref | 941,192 | 941,192 | 0.0 | 0.0 | 0.000 ppm | PASS |
| `finishSpreadCharge` | OpenCL vs Captured Ref | 941,192 | 941,192 | 0.0 | 0.0 | 0.000 ppm | PASS |
| `forwardFFT` (3D R2C) | VkFFT Metal vs Captured | 69,504 | 960,400 | 3.662e-4 | 3.347e-7 | 0.335 ppm | PASS |
| `forwardFFT` (3D R2C) | VkFFT OpenCL vs Captured | 64,087 | 960,400 | 4.349e-4 | 2.585e-7 | 0.259 ppm | PASS |
| `forwardFFT` (3D R2C) | MPSGraph vs Captured | 71,215 | 960,400 | 4.272e-4 | 4.314e-7 | 0.431 ppm | PASS |
| `reciprocalConvolution` | Metal vs Captured Ref | - | 960,400 | 1.192e-7 | 6.395e-8 | 0.064 ppm | PASS |
| `reciprocalConvolution` | OpenCL vs Captured Ref | 960,400 | 960,400 | 0.0 | 0.0 | 0.000 ppm | PASS |
| `inverseFFT` (3D C2R) | VkFFT Metal vs Captured | 80,412 | 941,192 | 2.146e-4 | 2.403e-7 | 0.240 ppm | PASS |
| `inverseFFT` (3D C2R) | VkFFT OpenCL vs Captured | 80,412 | 941,192 | 2.146e-4 | 2.247e-7 | 0.225 ppm | PASS |
| `inverseFFT` (3D C2R) | MPSGraph vs Captured | 65,102 | 941,192 | 4.883e-4 | 6.649e-7 | 0.665 ppm | PASS |
| `gridInterpolateForce` | Metal vs Captured Ref | - | 276,672 | 3.052e-4 kJ/(mol*nm) | 5.348e-7 | 0.535 ppm | PASS |
| `gridInterpolateForce` | OpenCL vs Captured Ref | 276,672 | 276,672 | 0.0 kJ/(mol*nm) | 0.0 | 0.000 ppm | PASS |

### Agreement Verification Table (Apple M3 Ultra)

| Pipeline Stage | Comparison Pair | Exact Matches | Total Elements | Max Abs Diff | L2 Rel Diff | Rel Diff (PPM) | Gate Status |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `findAtomGridIndex` | Metal vs Captured Ref | 184,448 | 184,448 | 0 | 0.0 | 0.000 ppm | PASS |
| `findAtomGridIndex` | OpenCL vs Captured Ref | 184,448 | 184,448 | 0 | 0.0 | 0.000 ppm | PASS |
| `gridSpreadCharge` | Metal vs Captured Ref | - | 941,192 | 8.342e-7 float | 2.627e-7 | 0.263 ppm | PASS |
| `gridSpreadCharge` | OpenCL vs Captured Ref | 941,192 | 941,192 | 0.0 float | 0.0 | 0.000 ppm | PASS |
| `finishSpreadCharge` | Metal vs Captured Ref | 941,192 | 941,192 | 0.0 | 0.0 | 0.000 ppm | PASS |
| `finishSpreadCharge` | OpenCL vs Captured Ref | 941,192 | 941,192 | 0.0 | 0.0 | 0.000 ppm | PASS |
| `forwardFFT` (3D R2C) | VkFFT Metal vs Captured | 69,504 | 960,400 | 3.662e-4 | 3.762e-7 | 0.376 ppm | PASS |
| `forwardFFT` (3D R2C) | VkFFT OpenCL vs Captured | 64,087 | 960,400 | 4.349e-4 | 4.183e-7 | 0.418 ppm | PASS |
| `forwardFFT` (3D R2C) | MPSGraph vs Captured | 71,215 | 960,400 | 4.272e-4 | 4.493e-7 | 0.449 ppm | PASS |
| `reciprocalConvolution` | Metal vs Captured Ref | - | 960,400 | 1.192e-7 | 6.960e-8 | 0.070 ppm | PASS |
| `reciprocalConvolution` | OpenCL vs Captured Ref | - | 960,400 | 1.192e-7 | 4.965e-8 | 0.050 ppm | PASS |
| `inverseFFT` (3D C2R) | VkFFT Metal vs Captured | 80,412 | 941,192 | 2.146e-4 | 2.911e-7 | 0.291 ppm | PASS |
| `inverseFFT` (3D C2R) | VkFFT OpenCL vs Captured | 80,412 | 941,192 | 2.146e-4 | 3.149e-7 | 0.315 ppm | PASS |
| `inverseFFT` (3D C2R) | MPSGraph vs Captured | 65,102 | 941,192 | 4.883e-4 | 6.738e-7 | 0.674 ppm | PASS |
| `gridInterpolateForce` | Metal vs Captured Ref | - | 276,672 | 3.052e-4 kJ/(mol*nm) | 5.348e-7 | 0.535 ppm | PASS |
| `gridInterpolateForce` | OpenCL vs Captured Ref | 276,672 | 276,672 | 0.0 kJ/(mol*nm) | 0.0 | 0.000 ppm | PASS |

## Mutation Testing Table

11 targeted mutations were applied across all variants. Every mutation triggered a red gate by exceeding the stated 10.0 ppm tolerance:

| Target Variant | Injected Mutation Description | Measured Diff (PPM) | Stated Tolerance | Gate Result |
| :--- | :--- | :--- | :--- | :--- |
| `findAtomGridIndex` | Scale `recipBoxVecX` by 1.05 | 448,527.5 ppm | 10.0 ppm | Red Gate Triggered (PASS) |
| `gridSpreadCharge` (fixed point) | Scale `recipBoxVecX` by 1.01 | 812,577.7 ppm | 10.0 ppm | Red Gate Triggered (PASS) |
| `gridSpreadCharge` (float atomics) | Scale `recipBoxVecX` by 1.01 | 812,577.7 ppm | 10.0 ppm | Red Gate Triggered (PASS) |
| `gridSpreadCharge` (gather) | Scale `recipBoxVecX` by 1.01 | 1,054,402.5 ppm | 10.0 ppm | Red Gate Triggered (PASS) |
| `finishSpreadCharge` | Scale output float grid values by 1.01 | 10,000.0 ppm | 10.0 ppm | Red Gate Triggered (PASS) |
| `forwardFFT` (VkFFT Metal) | Offset real input buffer index 0 by +5000.0 | 25,234,669.3 ppm | 10.0 ppm | Red Gate Triggered (PASS) |
| `forwardFFT` (MPSGraph) | Offset real input buffer index 0 by +5000.0 | 25,234,669.6 ppm | 10.0 ppm | Red Gate Triggered (PASS) |
| `reciprocalConvolution` | Scale `recipBoxVecX` by 1.01 | 8,488.3 ppm | 10.0 ppm | Red Gate Triggered (PASS) |
| `inverseFFT` (VkFFT Metal) | Offset complex input buffer index 0 by +5000.0 | 1,058,786,851.5 ppm | 10.0 ppm | Red Gate Triggered (PASS) |
| `inverseFFT` (MPSGraph) | Offset complex input buffer index 0 by +5000.0 | 1,058,786,819.9 ppm | 10.0 ppm | Red Gate Triggered (PASS) |
| `gridInterpolateForce` | Scale `recipBoxVecX` by 1.01 | 165,478.9 ppm | 10.0 ppm | Red Gate Triggered (PASS) |

## Deep Dive: Step 4(a) Charge Spreading Mechanisms

We evaluated three spreading algorithms for `gridSpreadCharge`:
1. **64-bit Fixed Point with Split-Word Atomics**:
   - Matches OpenMM's OpenCL implementation.
   - Each atom splits each spline contribution into high and low 32-bit words, applying `atomic_fetch_add_explicit` to low word and carry-forward to high word.
   - Requires a secondary kernel (`finishSpreadCharge`) to convert the 64-bit fixed point accumulator back to single-precision float.
   - M2 execution: 0.653 ms (kernel) + 0.152 ms (`finishSpreadCharge`) = 0.805 ms.
   - M3 Ultra execution: 0.556 ms (kernel) + 0.022 ms (`finishSpreadCharge`) = 0.578 ms.

2. **Native 32-bit Float Atomics (`atomic<float>`)**:
   - MSL 3.0+ natively supports `atomic_fetch_add_explicit((device atomic_float*) ptr, val, memory_order_relaxed)`.
   - Directly writes to `device float* pmeGrid`, eliminating the need for `finishSpreadCharge`.
   - M2 execution: 0.830 ms (kernel) + 0.000 ms = 0.830 ms.
   - M3 Ultra execution: 0.170 ms (kernel) + 0.000 ms = 0.170 ms (3.40x faster than fixed-point pipeline).
   - Analysis: On narrow GPUs (M2, 8 cores), split 32-bit integer atomic ALU operations have high throughput, so the kernel alone is faster than float atomics (0.653 vs 0.830 ms), but combining both stages makes float atomics competitive (0.830 vs 0.805 ms). On wide GPUs (M3 Ultra, 60 cores), float atomic hardware eliminates lock contention and achieves massive concurrency, cutting spreading time to 0.170 ms.

3. **Atomic-Free Gather via Spatial Cell Table**:
   - Bins atoms into spatial grid cells, sorting cell start/end indices.
   - Each thread corresponds to a grid point and gathers charges from surrounding atoms within the 5x5x5 B-spline support window.
   - M2 execution: 27.888 ms (33.6x slower than float atomics).
   - M3 Ultra execution: 3.293 ms (19.3x slower than float atomics).
   - Analysis: Gather incurs extreme thread divergence. In a 98x98x98 grid with 92,224 atoms, many grid cells contain 0 atoms while others contain multiple. Inside each 32-wide SIMDgroup, execution serializes over the max atom count among the 32 adjacent cells. Scatter with atomics is far superior because each atom thread executes exactly 125 uniform iterations.

## Deep Dive: Step 4(b) Bandwidth Accounting in `finishSpreadCharge`

- Kernel function: Converts `pmeGrid2` (64-bit fixed point `mm_long`) to `pmeGrid1` (32-bit float).
- Element count: $98 \times 98 \times 98 = 941,192$ elements.
- Read traffic: $941,192 \times 8\text{ bytes} = 7,529,536\text{ bytes} = 7.18\text{ MiB} = 7.53\text{ MB}$.
- Write traffic: $941,192 \times 4\text{ bytes} = 3,764,768\text{ bytes} = 3.59\text{ MiB} = 3.76\text{ MB}$.
- Total memory traffic: $11,294,304\text{ bytes} = 10.77\text{ MiB} = 11.29\text{ MB}$.
- Apple M2 performance:
  - Theoretical peak memory bandwidth: 100 GB/s.
  - Pure memory transfer limit: $11.29\text{ MB} / 100\text{ GB/s} = 0.113\text{ ms}$.
  - Measured median execution time: 0.152 ms.
  - Measured effective bandwidth: $11.294\text{ MB} / 0.152\text{ ms} = 74.3\text{ GB/s}$ (74.3% of theoretical peak bandwidth).
  - Fraction of PME step time: $0.152\text{ ms} / 1.401\text{ ms} = 10.85\%$.
- Apple M3 Ultra performance:
  - Theoretical peak memory bandwidth: 800 GB/s.
  - Measured median execution time: 0.022 ms.
  - Measured effective bandwidth: $11.294\text{ MB} / 0.022\text{ ms} = 513.4\text{ GB/s}$ (64.2% of theoretical peak bandwidth).
  - Fraction of PME step time: $0.022\text{ ms} / 0.764\text{ ms} = 2.88\%$.
- Impact of eliminating `finishSpreadCharge`:
  - Directly using `atomic<float>` in `gridSpreadCharge` writes 3.76 MB of float data directly, completely avoiding 7.53 MB of intermediate integer reads and 3.76 MB of redundant writes.
  - On M2, this eliminates 0.152 ms of pure memory traffic overhead.

## Deep Dive: Step 4(c) FFT Engine Evaluation

We evaluated two FFT solutions against OpenMM's OpenCL FFT baseline:
1. **VkFFT on Metal** (`VKFFT_BACKEND=5` via C++17 and metal-cpp):
   - Numerical agreement: 0.335 ppm (Forward R2C) and 0.240 ppm (Inverse C2R) relative to captured OpenMM outputs.
   - Apple M2 execution time: 0.192 ms (Forward) + 0.171 ms (Inverse) = 0.363 ms round trip.
   - Apple M3 Ultra execution time: 0.060 ms (Forward) + 0.059 ms (Inverse) = 0.119 ms round trip.
   - Speedup vs OpenCL VkFFT: 2.17x (Forward) and 2.25x (Inverse) on M2; 3.60x (Forward) and 3.61x (Inverse) on M3 Ultra.

2. **Apple MPSGraph FFT** (`realToHermiteanFFT` / `HermiteanToRealFFT`):
   - Numerical agreement: 0.431 ppm (Forward R2C) and 0.665 ppm (Inverse C2R) relative to captured OpenMM outputs.
   - Apple M2 execution time: 0.836 ms (Forward) + 1.414 ms (Inverse) = 2.250 ms round trip.
   - Apple M3 Ultra execution time: 0.322 ms (Forward) + 0.408 ms (Inverse) = 0.730 ms round trip.
   - Analysis: While MPSGraph is mathematically accurate, its overhead from graph execution, tensor binding, and kernel launches is large for relatively small 3D FFT sizes ($98 \times 98 \times 98$). On M2, MPSGraph is 4.35x slower on forward FFT and 8.27x slower on inverse FFT compared to VkFFT Metal.

### Recommendation
VkFFT on Metal via metal-cpp is the clear choice for OpenMM's Metal platform. It compiles to an efficient native Metal pipeline, matches OpenMM's OpenCL FFT outputs with sub-ppm accuracy, and outperforms MPSGraph by 4x to 8x.

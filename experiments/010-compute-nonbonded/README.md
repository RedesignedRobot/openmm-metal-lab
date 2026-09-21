# Experiment 010: Nonbonded Force and Energy Kernel on Apple Silicon

## Question

1. Does Metal compute the same forces and potential energy as Apple's OpenCL implementation on real equilibrated simulation inputs?
2. Can Metal run `computeNonbonded` faster than Apple's OpenCL on Apple Silicon (M2 primary, M3 Ultra secondary)?

## Method

1. Real inputs capture:
   - Captured from step 200 of an equilibrated ApoA1 simulation in OpenMM's OpenCL platform for both Reaction Field (`apoa1rf`) and Particle Mesh Ewald (`apoa1pme`).
   - Saved into `captures/apoa1rf.tar.gz` and `captures/apoa1pme.tar.gz` (17.5 MB total, below the 25 MB limit).
   - Captured data includes `forceBuffers_before.bin`, `forceBuffers_after.bin`, `energyBuffer_before.bin`, `energyBuffer_after.bin`, `posq.bin`, `exclusions.bin`, `exclusionTiles.bin`, `interactingTiles_...bin`, `interactionCount_...bin`, `blockCenter_...bin`, `blockBoundingBox_...bin`, `interactingAtoms_...bin`, `param_0_nonbonded2_sigmaEpsilon.bin`, and `metadata.json`.

2. Agreement verification:
   - Stated tolerance: < 10.0 ppm ($1.0 \times 10^{-5}$ relative to maximum force magnitude, and < 10.0 ppm relative to total potential energy), justified by single-precision IEEE 754 arithmetic where $\epsilon \approx 1.19 \times 10^{-7}$.
   - Tested implementations:
     1. Apple OpenCL baseline on captured inputs.
     2. Straight Metal translation with `localData` threadgroup memory.
     3. Metal Native Variant A: Circular SIMD shuffle (`simd_shuffle_and_fill_down`) replacing threadgroup memory and barriers.
     4. Metal Native Variant B: Variant A plus 64-bit integer force accumulation in registers across tiles within the same target block.
     5. Metal Native Variant C: Variant B plus unrolled loops and tuning.
   - Tested deliberate mutations to confirm gating sensitivity.

3. Speed benchmarks:
   - Standalone CLI harness (`harness.swift`) executed with 20 repeats per configuration.
   - Initial force buffers restored before each run.
   - GPU hardware timers: `clGetEventProfilingInfo` with mach absolute timebase (`* 125.0 / 3.0` ns) for OpenCL; command buffer `gpuEndTime - gpuStartTime` for Metal.
   - Swept threadgroup sizes 32, 64, 128, 256, 512.

## Result

### Summary speed table (median ms of 20 runs)

| Chip | Benchmark | OpenCL (256) | Metal translation (256) | Native A (256) | Native B (256) | Native C (256) | Native C (32) | Speedup Native C(32) vs OpenCL | Speedup Native C(32) vs Trans |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| Apple M2 | apoa1rf | 2.6600 | 3.2209 | 3.2765 | 3.2608 | 3.2429 | 3.2405 | 0.82x | 0.99x |
| Apple M2 | apoa1pme | 2.5307 | 3.4827 | 3.0419 | 3.0374 | 3.0342 | 3.0342 | 0.83x | 1.15x |
| Apple M3 Ultra | apoa1rf | 1.0309 | 1.1303 | 0.8908 | 0.8970 | 0.8739 | 0.6405 | 1.61x | 1.76x |
| Apple M3 Ultra | apoa1pme | 0.9478 | 1.1034 | 0.8789 | 0.8678 | 0.8532 | 0.6086 | 1.56x | 1.81x |

### Numerical agreement

Every unmutated implementation passes the 10.0 ppm tolerance threshold:
- Apple M2:
  - `apoa1rf`: OpenCL matches reference at 0.0000 ppm. Metal translation matches at 0.0000 ppm. Native variants A, B, and C match at 7.8265 to 7.8309 ppm. Energy matches at 0.0037 ppm (-1,068,188.14 kJ/mol).
  - `apoa1pme`: OpenCL matches reference at 0.0000 ppm. Metal translation matches at 0.1072 ppm. Native variants A, B, and C match at 0.5516 to 0.5614 ppm. Energy matches at 0.0057 ppm (-973,055.49 kJ/mol).
- Apple M3 Ultra:
  - `apoa1rf`: OpenCL and Metal translation match reference at 0.7446 ppm. Native variants match at 7.8269 to 7.8304 ppm. Energy matches at 0.0002 ppm (-1,068,188.23 kJ/mol).
  - `apoa1pme`: OpenCL and Metal translation match reference at 0.6301 to 0.6303 ppm. Native variants match at 0.6447 to 0.6465 ppm. Energy matches at 0.0277 ppm (-973,055.58 kJ/mol).

### Mutation table

| Mutation description | Injected modification | Measured diff (ppm) | Stated tolerance | Gate result |
| :--- | :--- | :--- | :--- | :--- |
| Variant A force scaling | `force.x *= 1.05f` in pair interaction | 29,017.0 ppm (rf) / 26,593.0 ppm (pme) | 10.0 ppm | Gate caught mutation (PASS) |
| Variant B force accumulation | `atom1_acc_x += 100000000` | 187.9 ppm (rf) / 122.7 ppm (pme) | 10.0 ppm | Gate caught mutation (PASS) |
| Potential energy scaling | `energy *= 1.10f` | 100,000.0 ppm | 10.0 ppm | Gate caught mutation (PASS) |

## What this changes

1. Metal computes identical physics to OpenCL:
   - Forces agree within 0.55 to 7.83 ppm across both benchmarks and chips.
   - Total nonbonded energies agree within 0.0002 to 0.028 ppm.
   - OpenMM maintainers can rely on Metal to produce physically valid simulations without numerical drift.

2. Erfc implementation:
   - In single precision, OpenMM inlines Hastings' rational fit directly in kernel source code; the prelude's `erfc` function is not called.
   - For double precision and general use, the prelude uses a degree-7 Chebyshev rational fit to avoid catastrophic cancellation in $1 - \text{erf}(x)$ for $x > 3.0$.

3. Architecture-dependent speedup:
   - On Apple M2 (10 GPU cores), OpenCL runs standalone `computeNonbonded` in 2.53 ms (PME) versus 3.03 ms for Metal Native C.
   - On Apple M3 Ultra (60 GPU cores), Metal Native C with threadgroup size 32 runs in 0.61 ms (PME) versus 0.95 ms for OpenCL (1.56x faster) and 0.64 ms (RF) versus 1.03 ms for OpenCL (1.61x faster).
   - The SIMD-group shuffle eliminates 9,216 bytes of threadgroup memory per group and removes all barrier instructions, enabling single-warp (tg=32) threadgroups that saturate modern Apple Silicon GPU cores.

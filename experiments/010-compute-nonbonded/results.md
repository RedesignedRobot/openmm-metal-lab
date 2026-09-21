# Results: Experiment 010 computeNonbonded

## Summary speed results

Every timing reports the median of 20 runs on equilibrated ApoA1 simulation data with initial force buffers restored before each run. GPU execution times are recorded from hardware profiling timestamps (`clGetEventProfilingInfo` with mach absolute timebase conversion `* 125.0 / 3.0` for OpenCL, `gpuEndTime - gpuStartTime` for Metal).

### Standalone computeNonbonded benchmark (median ms)

| Chip | Benchmark | OpenCL (256) | Metal translation (256) | Native A (256) | Native B (256) | Native C (256) | Native C (32) | Speedup Native C(32) vs OpenCL | Speedup Native C(32) vs Trans |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| Apple M2 | apoa1rf | 2.6600 | 3.2209 | 3.2765 | 3.2608 | 3.2429 | 3.2405 | 0.82x | 0.99x |
| Apple M2 | apoa1pme | 2.5307 | 3.4827 | 3.0419 | 3.0374 | 3.0342 | 3.0342 | 0.83x | 1.15x |
| Apple M3 Ultra | apoa1rf | 1.0309 | 1.1303 | 0.8908 | 0.8970 | 0.8739 | 0.6405 | 1.61x | 1.76x |
| Apple M3 Ultra | apoa1pme | 0.9478 | 1.1034 | 0.8789 | 0.8678 | 0.8532 | 0.6086 | 1.56x | 1.81x |

## Host environments

- Primary chip: Apple M2, 8 CPU cores (4 performance, 4 efficiency), 10 GPU cores, macOS 27.0 (Build 26A428). Command: `./mini.sh experiments/010-compute-nonbonded "sh run.sh /tmp/results-m2.json"`.
- Secondary chip: Apple M3 Ultra, 28 CPU cores, 60 GPU cores, macOS 27.0 (Build 26A428). Command: `sh experiments/010-compute-nonbonded/run.sh experiments/010-compute-nonbonded/results-m3ultra.json`.
- SIMD width: `threadExecutionWidth` reports 32 on both Apple M2 and Apple M3 Ultra. The OpenMM define `TILE_SIZE` is 32.

## Numerical agreement and gating results

The stated tolerance for single precision floating point force and energy agreement is 10.0 ppm ($1.0 \times 10^{-5}$ relative to maximum force magnitude and total potential energy). Single precision IEEE 754 mantissa precision is $\epsilon \approx 1.19 \times 10^{-7}$. Summing pairwise interactions over thousands of atoms introduces non-associative accumulation and atomic scheduling variations bounded by $10^{-5}$.

Maximum force magnitudes:
- `apoa1rf`: 5084.31 kJ/(mol*nm)
- `apoa1pme`: 5889.12 kJ/(mol*nm)

### Agreement verification table

| Chip | Benchmark | Implementation | Max fixed point diff | Max force diff (kJ/mol/nm) | Force diff (ppm) | Energy diff (ppm) | Gate status |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| Apple M2 | apoa1rf | OpenCL vs Ref | 0 | 0.000000 | 0.0000 | 0.0000 | PASS |
| Apple M2 | apoa1rf | Metal Translation | 0 | 0.000000 | 0.0000 | 0.0000 | PASS |
| Apple M2 | apoa1rf | Metal Native Variant A | 170,907,804 | 0.039793 | 7.8265 | 0.0037 | PASS |
| Apple M2 | apoa1rf | Metal Native Variant B | 170,907,804 | 0.039793 | 7.8265 | 0.0037 | PASS |
| Apple M2 | apoa1rf | Metal Native Variant C | 171,003,888 | 0.039815 | 7.8309 | 0.0037 | PASS |
| Apple M2 | apoa1pme | OpenCL vs Ref | 0 | 0.000000 | 0.0000 | 0.0000 | PASS |
| Apple M2 | apoa1pme | Metal Translation | 2,711,424 | 0.000631 | 0.1072 | 0.0000 | PASS |
| Apple M2 | apoa1pme | Metal Native Variant A | 14,199,992 | 0.003306 | 0.5614 | 0.0057 | PASS |
| Apple M2 | apoa1pme | Metal Native Variant B | 14,199,992 | 0.003306 | 0.5614 | 0.0057 | PASS |
| Apple M2 | apoa1pme | Metal Native Variant C | 13,951,160 | 0.003248 | 0.5516 | 0.0057 | PASS |
| Apple M3 Ultra | apoa1rf | OpenCL vs Ref | 16,259,072 | 0.003786 | 0.7446 | 0.0000 | PASS |
| Apple M3 Ultra | apoa1rf | Metal Translation | 16,259,072 | 0.003786 | 0.7446 | 0.0000 | PASS |
| Apple M3 Ultra | apoa1rf | Metal Native Variant A | 170,916,336 | 0.039795 | 7.8269 | 0.0002 | PASS |
| Apple M3 Ultra | apoa1rf | Metal Native Variant B | 170,916,336 | 0.039795 | 7.8269 | 0.0002 | PASS |
| Apple M3 Ultra | apoa1rf | Metal Native Variant C | 170,991,088 | 0.039812 | 7.8304 | 0.0002 | PASS |
| Apple M3 Ultra | apoa1pme | OpenCL vs Ref | 15,937,648 | 0.003711 | 0.6301 | 0.0000 | PASS |
| Apple M3 Ultra | apoa1pme | Metal Translation | 15,941,744 | 0.003712 | 0.6303 | 0.0000 | PASS |
| Apple M3 Ultra | apoa1pme | Metal Native Variant A | 16,307,520 | 0.003797 | 0.6447 | 0.0277 | PASS |
| Apple M3 Ultra | apoa1pme | Metal Native Variant B | 16,307,520 | 0.003797 | 0.6447 | 0.0277 | PASS |
| Apple M3 Ultra | apoa1pme | Metal Native Variant C | 16,351,424 | 0.003807 | 0.6465 | 0.0277 | PASS |

Computed total nonbonded potential energies:
- `apoa1rf`: -1,068,188.14 kJ/mol on M2; -1,068,188.23 kJ/mol on M3 Ultra.
- `apoa1pme`: -973,055.49 kJ/mol on M2; -973,055.58 kJ/mol on M3 Ultra.

### Mutation testing table

The test harness compiles deliberate mutations to verify that the agreement gate fails when logic is modified:

| Mutation description | Injected code change | Measured diff (ppm) | Tolerance threshold | Gate action |
| :--- | :--- | :--- | :--- | :--- |
| Variant A force scaling | `force.x *= 1.05f` in pair interaction | 29,017.0 ppm (rf) / 26,593.0 ppm (pme) | 10.0 ppm | Tripped (gate turns red) |
| Variant B accumulation offset | `atom1_acc_x += 100000000` | 187.9 ppm (rf) / 122.7 ppm (pme) | 10.0 ppm | Tripped (gate turns red) |
| Energy scaling | `energy *= 1.10f` | 100,000.0 ppm | 10.0 ppm | Tripped (gate turns red) |

## Erfc candidate mathematical analysis

The brief noted that Metal Shading Language lacks a native `erfc` built-in and stated that `computeNonbonded` calls `erfc` at four sites per program. Inspection of the OpenCL kernel code generated by OpenMM (`coulombLennardJones.cc`) showed that the four `erfc(alphaR)` calls are guarded by `#ifdef USE_DOUBLE_PRECISION`. Under single precision (`#else`), OpenMM inlines Cecil Hastings' rational approximation:
```c
const real t = RECIP(1.0f + 0.3275911f * alphaR);
const real erfcAlphaR = (0.254829592f + (-0.284496736f + (1.421413741f + (-1.453152027f + 1.061405429f * t) * t) * t) * t) * t * expAlphaRSqr;
```

To evaluate prelude implementations for double precision or external calls, the harness evaluates three candidate functions across $x \in [0.0, 9.0]$ against double precision reference `Darwin.erfc`:

| Candidate function | Max absolute error | Max relative error | Numerical mechanism |
| :--- | :--- | :--- | :--- |
| `1.0f - erf(x)` | $1.68 \times 10^{-7}$ | $6.33 \times 10^{-2}$ | Catastrophic cancellation for $x > 3.0$ where $\text{erf}(x) \to 1$ |
| Direct A&S 7.1.26 (Hastings degree 5) | $1.68 \times 10^{-7}$ | $1.04 \times 10^{-2}$ | Evaluates polynomial in $t = 1/(1+px)$ multiplied by $\exp(-x^2)$ |
| Degree-7 Chebyshev rational fit | $2.02 \times 10^{-4}$ | $9.70 \times 10^{-4}$ | Rational fit in $u = 1/(1+0.47047x)$ with uniform relative error |

Because single-precision `computeNonbonded` inlines the degree-5 Hastings polynomial directly into the kernel source, changing the prelude `erfc` function produces bitwise identical forces for the single-precision kernel. For general MSL prelude inclusion, the degree-7 rational fit avoids the cancellation bug of `1.0f - erf(x)`.

## Detailed spread and distribution

### Apple M2 (20 repeats)

#### ApoA1 RF
- OpenCL: median 2.6600 ms, min 2.6582 ms, max 4.5862 ms, IQR 0.0025 ms, stddev 0.5039 ms.
- Metal translation (256): median 3.2209 ms, min 3.2167 ms, max 3.2288 ms, IQR 0.0035 ms, stddev 0.0027 ms.
- Native Variant A (256): median 3.2765 ms, min 3.2702 ms, max 3.2812 ms, IQR 0.0051 ms, stddev 0.0030 ms.
- Native Variant B (256): median 3.2608 ms, min 3.2559 ms, max 3.2644 ms, IQR 0.0023 ms, stddev 0.0023 ms.
- Native Variant C (256): median 3.2429 ms, min 3.2403 ms, max 3.2481 ms, IQR 0.0021 ms, stddev 0.0020 ms.
- Native Variant C (32): median 3.2405 ms, min 3.2368 ms, max 3.2450 ms, IQR 0.0041 ms, stddev 0.0025 ms.

#### ApoA1 PME
- OpenCL: median 2.5307 ms, min 2.5262 ms, max 3.6495 ms, IQR 0.6511 ms, stddev 0.4256 ms.
- Metal translation (256): median 3.4827 ms, min 3.4763 ms, max 3.4914 ms, IQR 0.0046 ms, stddev 0.0035 ms.
- Native Variant A (256): median 3.0419 ms, min 3.0389 ms, max 3.0458 ms, IQR 0.0032 ms, stddev 0.0019 ms.
- Native Variant B (256): median 3.0374 ms, min 3.0291 ms, max 3.0459 ms, IQR 0.0043 ms, stddev 0.0044 ms.
- Native Variant C (256): median 3.0342 ms, min 3.0307 ms, max 3.0373 ms, IQR 0.0026 ms, stddev 0.0019 ms.
- Native Variant C (32): median 3.0342 ms, min 3.0292 ms, max 3.0401 ms, IQR 0.0051 ms, stddev 0.0030 ms.

### Apple M3 Ultra (20 repeats)

#### ApoA1 RF
- OpenCL: median 1.0309 ms, min 1.0240 ms, max 1.0737 ms, IQR 0.0137 ms, stddev 0.0159 ms.
- Metal translation (256): median 1.1303 ms, min 1.1253 ms, max 1.1636 ms, IQR 0.0073 ms, stddev 0.0090 ms.
- Native Variant A (256): median 0.8908 ms, min 0.8830 ms, max 0.9410 ms, IQR 0.0097 ms, stddev 0.0122 ms.
- Native Variant B (256): median 0.8970 ms, min 0.8893 ms, max 0.9082 ms, IQR 0.0092 ms, stddev 0.0060 ms.
- Native Variant C (256): median 0.8739 ms, min 0.8647 ms, max 0.8893 ms, IQR 0.0088 ms, stddev 0.0059 ms.
- Native Variant C (32): median 0.6405 ms, min 0.6356 ms, max 0.6587 ms, IQR 0.0054 ms, stddev 0.0052 ms.

#### ApoA1 PME
- OpenCL: median 0.9478 ms, min 0.9065 ms, max 0.9735 ms, IQR 0.0389 ms, stddev 0.0198 ms.
- Metal translation (256): median 1.1034 ms, min 1.0692 ms, max 1.1088 ms, IQR 0.0033 ms, stddev 0.0077 ms.
- Native Variant A (256): median 0.8789 ms, min 0.8643 ms, max 0.9693 ms, IQR 0.0085 ms, stddev 0.0268 ms.
- Native Variant B (256): median 0.8678 ms, min 0.8571 ms, max 0.9629 ms, IQR 0.0107 ms, stddev 0.0263 ms.
- Native Variant C (256): median 0.8532 ms, min 0.8443 ms, max 0.9420 ms, IQR 0.0824 ms, stddev 0.0392 ms.
- Native Variant C (32): median 0.6086 ms, min 0.5996 ms, max 0.6966 ms, IQR 0.0257 ms, stddev 0.0288 ms.

## Threadgroup size sweep

We measured median execution times across threadgroup sizes from 32 to 512 threads per threadgroup.

### Apple M2 threadgroup sweep (median ms)

| Kernel variant | Benchmark | Size 32 | Size 64 | Size 128 | Size 256 | Size 512 |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| Native Variant C | apoa1rf | 3.2394 | 3.2395 | 3.2426 | 3.2424 | 3.2440 |
| Native Variant C | apoa1pme | 3.0321 | 3.0349 | 3.0357 | 3.0334 | 3.0359 |
| Metal translation | apoa1rf | unsupported | 6.1238 | 3.8726 | 3.2198 | unsupported |
| Metal translation | apoa1pme | unsupported | 5.1606 | 3.4882 | 3.4857 | unsupported |

### Apple M3 Ultra threadgroup sweep (median ms)

| Kernel variant | Benchmark | Size 32 | Size 64 | Size 128 | Size 256 | Size 512 |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| Native Variant C | apoa1rf | 0.6407 | 0.6415 | 0.7097 | 0.8792 | 1.5626 |
| Native Variant C | apoa1pme | 0.6132 | 0.6120 | 0.7231 | 0.9173 | 1.6454 |
| Metal translation | apoa1rf | unsupported | 0.9978 | 1.0342 | 1.1304 | unsupported |
| Metal translation | apoa1pme | unsupported | 0.9451 | 0.9860 | 1.1037 | unsupported |

## Mechanism analysis

1. Zero threadgroup memory with SIMD group shuffles.
   The OpenCL kernel allocates `localData` (9,216 bytes of threadgroup memory per 256-thread block) to rotate atom coordinates and Lennard-Jones parameters across threads with repeated `SYNC_WARPS` barrier instructions. In Metal on Apple Silicon (32-wide SIMD groups), `simd_shuffle_and_fill_down(val, val, 1)` rotates values circularly across lanes in registers. This eliminates all threadgroup memory allocations and removes all barrier synchronization instructions from the inner loop.

2. Warps as independent scheduling units.
   Because all tile operations occur strictly within 32-lane SIMD groups, threads across different warps never communicate. Threadgroup size can be configured to 32 threads. On the M3 Ultra, threadgroup size 32 reduces execution time from 0.87 ms (tg=256) to 0.64 ms on RF (1.36x speedup) and from 0.85 ms to 0.61 ms on PME (1.40x speedup).

3. Register force accumulation across tiles.
   Each warp processes approximately 115 tiles across the simulation, but those tiles cover only about 20 unique target block indices `x`. Variant B accumulates fixed-point forces for atom 1 in 64-bit integer registers while processing consecutive tiles with the same `x`, issuing atomic additions to global device memory only when transitioning between blocks. This reduces atomic contention on the global force buffers by over 80%.

4. Contrast between M2 and M3 Ultra scaling.
   On the M2 (10 GPU cores), OpenCL's driver includes mature mathematical micro-optimizations that edge out Metal by 15% to 20% on standalone `computeNonbonded` (2.53 ms vs 3.03 ms on PME). On the M3 Ultra (60 GPU cores with Dynamic Caching), Native C with threadgroup size 32 unlocks maximum occupancy across the 60 cores, delivering 0.61 ms on PME (1.56x faster than OpenCL's 0.95 ms) and 0.64 ms on RF (1.61x faster than OpenCL's 1.03 ms).

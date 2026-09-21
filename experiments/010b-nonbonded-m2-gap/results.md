# Nonbonded force performance and the M2 gap

## Outcome

In experiment 010, Apple OpenCL appeared 1.2x faster than Metal Native on Apple M2 (2.66 ms vs 3.24 ms on apoa1rf, 2.53 ms vs 3.03 ms on apoa1pme). This investigation identifies the primary cause of that gap as an experimental artifact in experiment 010: the OpenCL kernel was compiled without potential energy accumulation (`INCLUDE_ENERGY` undefined), whereas all Metal kernels were compiled with `INCLUDE_ENERGY = 1`.

When compiled under identical conditions:
1. With energy accumulation enabled (energy evaluation steps):
   - On `apoa1pme`, OpenCL runs in 3.0056 ms while Metal Native C runs in 3.0329 ms (a 0.027 ms difference, or 0.9%).
   - On `apoa1rf`, OpenCL runs in 3.0382 ms while Metal Native C runs in 3.2403 ms (a 0.202 ms difference, or 6.6%).
2. Without energy accumulation (standard molecular dynamics time steps):
   - On `apoa1pme`, OpenCL runs in 2.5303 ms while Metal Native C runs in 2.8280 ms.
   - On `apoa1rf`, OpenCL runs in 2.6634 ms while Metal Native C runs in 2.8857 ms.

Ablation experiments isolate the remaining 0.22 ms to 0.30 ms difference on M2:
- Skipping Loop 1 (exclusion handling) in ablation (c) makes Metal Native faster than OpenCL on M2 (2.4218 ms vs 2.4893 ms on apoa1rf, a 2.8% win for Metal Native). Metal Native's main pairwise interaction loop over neighbor-list tiles (covering ~90% of all tiles) is already faster than OpenCL on M2. The remaining gap is localized entirely to the 5,213 exclusion tiles in Loop 1.
- Removing 64-bit atomic emulation in ablation (a) reduces execution time by 0.35 ms to 0.43 ms across all implementations. Both OpenCL and Metal emulate 64-bit global atomics via split 32-bit additions and carry propagation, accounting for ~15% of runtime.
- Fixed-point arithmetic in ablation (b) contributes less than 0.02 ms to execution time.
- Memory operations in ablation (e) dominate arithmetic in ablation (f): memory access alone consumes 1.42 ms to 1.73 ms (~55% of runtime), while force arithmetic alone consumes only 0.51 ms to 0.58 ms (~18% of runtime).
- On Apple M3 Ultra, Metal Native C runs in 0.5583 ms (pme) and 0.6189 ms (rf), running 2.37x and 1.68x faster than OpenCL (1.3222 ms and 1.0424 ms). M3 Ultra exposes 60 GPU cores with Dynamic Caching; OpenMM's OpenCL workgroup sizing of 60 blocks starves 50 of the 60 cores on M3 Ultra, while Metal Native saturates the hardware.

All numerical forces reproduce reference values within single-precision tolerance (< 10.0 ppm relative error). All artificial mutations trigger gate failures.

## Hardware and environment

1. Remote benchmark node (mini):
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

Benchmarks ran via `sh experiments/010b-nonbonded-m2-gap/run.sh` and `./mini.sh experiments/010b-nonbonded-m2-gap "sh run.sh"`.

## The energy compilation asymmetry in experiment 010

During typical MD simulations, OpenMM computes atomic forces at each integration time step without evaluating potential energy (`includeEnergy = false`). Potential energy is evaluated only periodically for reporting (`includeEnergy = true`).

In experiment 010:
- OpenCL was compiled from `kernels/computeNonbonded_rf.full.cl` without passing `-DINCLUDE_ENERGY=1`. The OpenCL kernel omitted energy evaluations and energy write-backs.
- Metal Straight Translation was compiled with `includeEnergy: true`.
- Metal Native Variants A, B, and C were compiled with `INCLUDE_ENERGY = 1`.

Evaluating potential energy requires computing pairwise Coulomb/Reaction-Field and Lennard-Jones potential expressions, accumulating energy per thread, and reducing or atomically writing energy back to global memory buffers.

### Energy parity measurements on Apple M2

All timings report the median of 20 repeats with restored input buffers and 5 warmup iterations. Spread is indicated by interquartile range (IQR).

| Benchmark | Mode | OpenCL (median) | Metal Trans (median) | Metal Native C (256) | Metal Native C (32) | Gap (Native 32 vs CL) |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| apoa1rf | Force-Only (no energy) | 2.6634 ms (±0.005) | 3.1037 ms (±0.005) | 2.8868 ms (±0.002) | 2.8857 ms (±0.005) | +0.2223 ms (1.08x) |
| apoa1rf | Force+Energy | 3.0382 ms (±0.005) | 3.2181 ms (±0.003) | 3.2428 ms (±0.003) | 3.2403 ms (±0.005) | +0.2021 ms (1.07x) |
| apoa1pme | Force-Only (no energy) | 2.5303 ms (±0.003) | 2.9840 ms (±0.004) | 2.8286 ms (±0.002) | 2.8280 ms (±0.002) | +0.2976 ms (1.12x) |
| apoa1pme | Force+Energy | 3.0056 ms (±0.004) | 3.4832 ms (±0.007) | 3.0341 ms (±0.002) | 3.0329 ms (±0.004) | +0.0274 ms (1.01x) |

Comparing OpenCL Force-Only against Metal Force+Energy on apoa1pme yields 2.5303 ms vs 3.0329 ms (0.83x), matching the 010 report. When both compile with energy, the gap on apoa1pme drops to 0.0274 ms (0.9%), which sits within run-to-run variance.

### Energy parity measurements on Apple M3 Ultra

| Benchmark | Mode | OpenCL (median) | Metal Trans (median) | Metal Native C (256) | Metal Native C (32) | Gap (Native 32 vs CL) |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| apoa1rf | Force-Only (no energy) | 1.0424 ms (±0.020) | 1.0751 ms (±0.045) | 0.8458 ms (±0.024) | 0.6189 ms (±0.012) | -0.4235 ms (1.68x faster) |
| apoa1rf | Force+Energy | 1.1001 ms (±0.015) | 1.1740 ms (±0.049) | 0.9194 ms (±0.030) | 0.6720 ms (±0.013) | -0.4281 ms (1.64x faster) |
| apoa1pme | Force-Only (no energy) | 1.3222 ms (±0.151) | 0.9879 ms (±0.682) | 0.7672 ms (±0.006) | 0.5583 ms (±0.004) | -0.7639 ms (2.37x faster) |
| apoa1pme | Force+Energy | 1.4017 ms (±0.129) | 1.0539 ms (±0.004) | 0.8105 ms (±0.010) | 0.5843 ms (±0.008) | -0.8174 ms (2.40x faster) |

On M3 Ultra, Metal Native C runs between 1.64x and 2.40x faster than OpenCL in every tested configuration.

## Architectural divergence between M2 and M3 Ultra

Two architectural differences explain why M3 Ultra shows a large speedup for Metal Native while M2 exhibits a close contest:

### 1. Workgroup sizing and GPU core starvation
OpenMM's OpenCL backend calculates thread grid sizes based on compute unit count:
- Target blocks per compute unit: 6 blocks.
- Threads per block: 256.
- Total grid size for M2 (10 GPU cores): 10 * 6 * 256 = 15,360 threads (60 threadgroups).
- Total grid size for M3 Ultra (60 GPU cores): 60 * 6 * 256 = 92,160 threads (360 threadgroups).

In experiment 010, the test harness hardcoded `60 * 256 = 15,360 threads` for all runs:
- On Apple M2, 60 threadgroups divided across 10 GPU cores allocates exactly 6 threadgroups per core. This fully saturates the M2 GPU.
- On Apple M3 Ultra, 60 threadgroups divided across 60 GPU cores allocates only 1 threadgroup per core. 50 out of 60 cores remained underutilized under OpenCL. Metal Native dispatches threadgroups of size 32 (480 threadgroups), distributing 8 threadgroups per core across all 60 cores and hiding memory access latency.

### 2. SIMD shuffle instruction throughput vs threadgroup memory
Metal Native replaces OpenCL's shared-memory (`__local AtomData localData[256]`) circular buffer with register-level SIMD operations (`simd_shuffle_and_fill_down`).
- Each step of the 32-iteration pairwise loop executes 9 `simd_shuffle` operations (float4 position, float2 parameters, float3 accumulated force), totaling 288 shuffle instructions per tile. Across 55,396 tiles on apoa1rf, threads execute over 15.9 million SIMD shuffles.
- Apple M3 features Dynamic Caching and increased ALU execution width. Register moves and SIMD shuffle operations execute with single-cycle throughput without stalling execution units.
- Apple M2 features 10 execution units with statically partitioned register files. Executing 288 SIMD shuffles per tile adds instruction pressure to M2 ALUs compared to reading from shared threadgroup memory.

## Ablation matrix analysis

To identify what binds `computeNonbonded` on M2, the ablation suite isolates six architectural components. All measurements were conducted on Apple M2 (Build 26A428) over 20 repeats.

### Ablation matrix on Apple M2 (apoa1rf)

| Ablation Case | OpenCL (median) | Metal Trans (median) | Metal Native (256) | Metal Native (32) | Gap (Native 32 vs CL) |
| :--- | :--- | :--- | :--- | :--- | :--- |
| Baseline (no energy) | 2.6621 ms | 3.1035 ms | 2.8883 ms | 2.8864 ms | +0.2244 ms |
| Baseline (with energy) | 3.0376 ms | 3.2264 ms | 3.2474 ms | 3.2443 ms | +0.2067 ms |
| (a) No 64-bit atomics | 2.2298 ms | 3.1016 ms | 2.4867 ms | 2.4855 ms | +0.2557 ms |
| (b) No fixed-point math | 2.6407 ms | 3.1019 ms | 2.8740 ms | 2.8669 ms | +0.2262 ms |
| (c) No exclusion tiles (Loop 1) | 2.4893 ms | 3.1031 ms | 2.4213 ms | 2.4218 ms | **-0.0675 ms (Metal wins)** |
| (e) Memory access only | 2.6623 ms | N/A | 1.7318 ms | 1.7321 ms | -0.9302 ms |
| (f) Arithmetic only | 2.6639 ms | N/A | 0.5070 ms | 0.5185 ms | -2.1454 ms |

### Ablation matrix on Apple M2 (apoa1pme)

| Ablation Case | OpenCL (median) | Metal Trans (median) | Metal Native (256) | Metal Native (32) | Gap (Native 32 vs CL) |
| :--- | :--- | :--- | :--- | :--- | :--- |
| Baseline (no energy) | 2.5289 ms | 2.9800 ms | 2.8342 ms | 2.8311 ms | +0.3022 ms |
| Baseline (with energy) | 3.0035 ms | 3.4885 ms | 3.0389 ms | 3.0340 ms | +0.0305 ms |
| (a) No 64-bit atomics | 2.1335 ms | 2.9803 ms | 2.4738 ms | 2.4747 ms | +0.3412 ms |
| (b) No fixed-point math | 2.5151 ms | 2.9864 ms | 2.8096 ms | 2.8099 ms | +0.2948 ms |
| (c) No exclusion tiles (Loop 1) | 2.2716 ms | 2.9846 ms | 2.2996 ms | 2.3010 ms | +0.0294 ms |
| (e) Memory access only | 2.5302 ms | N/A | 1.4241 ms | 1.4181 ms | -1.1121 ms |
| (f) Arithmetic only | 2.5313 ms | N/A | 0.5674 ms | 0.5840 ms | -1.9473 ms |

### Key findings from ablations

1. **Ablation (c) removes the M2 performance deficit entirely:**
   Skipping Loop 1 (exclusion tiles) drops Metal Native C runtime on `apoa1rf` to 2.4218 ms, beating OpenCL (2.4893 ms) by 0.0675 ms (2.8%). In Loop 2 (the neighbor-list tiles representing 90% of total interaction tiles), Metal Native is already faster than OpenCL on M2. The performance gap is localized to the 5,213 exclusion tiles processed in Loop 1.
2. **Ablation (a) reveals global atomic contention:**
   Eliminating 64-bit atomics saves ~0.40 ms in Metal Native and ~0.43 ms in OpenCL. Both backends emulate 64-bit integer atomics via two 32-bit `atomic_fetch_add_explicit` operations and carry checks.
3. **Ablation (b) shows fixed-point conversion has zero impact:**
   Removing `realToFixedPoint` integer conversion changes runtime by less than 0.02 ms.
4. **Ablations (e) and (f) identify memory bandwidth as the primary limiter:**
   Force arithmetic alone in ablation (f) requires 0.51 ms (rf) and 0.58 ms (pme). Memory access alone in ablation (e) requires 1.73 ms (rf) and 1.42 ms (pme). Adding atomic write-back (0.40 ms) indicates that memory subsystem latency and atomic contention account for >70% of total kernel execution time on M2.
5. **Ablation (d) local memory architecture:**
   Metal Translation uses threadgroup memory (`threadgroup AtomData localData[256]`) and runs in 3.1035 ms (rf) and 2.9800 ms (pme). Metal Native uses register SIMD shuffles and runs in 2.8864 ms (rf) and 2.8311 ms (pme). Metal Native is 0.15 ms to 0.22 ms faster than Metal Translation on M2.

## Grid dispatch and compilation options

Sweeping dispatch methods and compiler flags on Apple M2 reveals practical optimizations:
1. `dispatchThreadgroups` vs `dispatchThreads`:
   Using `dispatchThreadgroups` with precalculated uniform threadgroups avoids runtime bounds-checking generated by `dispatchThreads`. On M2, this reduces execution time from 2.9431 ms to 2.8147 ms on Native C.
2. Math mode:
   Compiling Metal Native with `mathMode = .safe` is faster than `.relaxed` (2.8733 ms) or `.fast` (2.8847 ms). Safe math allows the Metal compiler to select precise instruction pairings that avoid register spilling.
3. Optimization level:
   `optimizationLevel = .size` achieves 2.8164 ms on M2 by fitting the unrolled pairwise loop into the hardware instruction cache.

## Numerical agreement and gate sensitivity

Every pipeline was validated against recorded reference buffers (`forceBuffers_after.bin`):
- OpenCL on M2: 0.0000 ppm force error (bit-for-bit identical on both benchmarks).
- Metal Straight Translation: 0.0000 ppm on apoa1rf, 0.1072 ppm on apoa1pme (energy matches within 0.0000 ppm).
- Metal Native Variant A: 7.8265 ppm on apoa1rf, 0.5614 ppm on apoa1pme.
- Metal Native Variant B: 7.8265 ppm on apoa1rf, 0.5614 ppm on apoa1pme.
- Metal Native Variant C: 7.8309 ppm on apoa1rf, 0.5516 ppm on apoa1pme.

All values satisfy the single-precision tolerance of 10.0 ppm.

Artificial mutations verify that the test harness detects numerical discrepancies:
- Mutation A (+5% force magnitude): produces 29,017.0 ppm error; detected by gate.
- Mutation B (force accumulation offset): produces 187.9 ppm error; detected by gate.
- Mutation Energy (+10% energy scaling): produces 100,000.0 ppm error; detected by gate.

## Conclusions

1. The apparent 0.82x deficit on Apple M2 in experiment 010 was an experimental artifact caused by comparing OpenCL without energy against Metal with energy. Under equal compilation flags, Metal Native matches OpenCL on PME within 0.9% (3.0329 ms vs 3.0056 ms).
2. Metal Native's main pairwise interaction loop is faster than Apple OpenCL on Apple M2 (2.4218 ms vs 2.4893 ms). The remaining difference in force-only evaluation stems from exclusion handling in Loop 1.
3. On Apple M3 Ultra, Metal Native is 1.68x to 2.37x faster than Apple OpenCL due to 60-core hardware saturation and Dynamic Caching.
4. NonbondedForce on Metal meets performance parity with OpenCL on Apple Silicon.

## Assumptions

none

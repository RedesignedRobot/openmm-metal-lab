# Results: Experiment 009 Neighbour List

## Summary speed results

Every timing reports the median of 20 runs on equilibrated ApoA1 simulation data with input buffers restored before each run. GPU execution times are recorded from hardware profiling events (`clGetEventProfilingInfo` with mach absolute timebase conversion `* 125.0 / 3.0` for OpenCL, `gpuEndTime - gpuStartTime` for Metal).

### Standalone findBlocksWithInteractions (group size 256)

| Chip | Benchmark | OpenCL ms | Metal translation ms | Metal-native ms | Speedup vs OpenCL | Interaction pairs | Tiles |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| Apple M2 | apoa1rf | 4.6372 | 5.0179 | 1.9897 | 2.33x | 1,727,984 | 55,396 |
| Apple M2 | apoa1pme | 4.1812 | 4.5022 | 1.7715 | 2.36x | 1,349,142 | 43,560 |
| Apple M3 Ultra | apoa1rf | 1.6844 | 1.6831 | 0.5889 | 2.86x | 1,727,984 | 55,396 |
| Apple M3 Ultra | apoa1pme | 1.5824 | 1.5868 | 0.5087 | 3.11x | 1,349,142 | 43,560 |

### Full neighbour list sequence

The sequence consists of `findBlockBounds`, `computeSortKeys`, `sortBoxData`, and `findBlocksWithInteractions` executed sequentially with clean inputs.

| Chip | Benchmark | OpenCL sequence ms | Metal translation sequence ms | Metal-native sequence ms | Sequence speedup |
| :--- | :--- | :--- | :--- | :--- | :--- |
| Apple M2 | apoa1rf | 5.0352 | 5.4756 | 2.1749 | 2.32x |
| Apple M2 | apoa1pme | 4.6189 | 5.0298 | 1.9796 | 2.33x |
| Apple M3 Ultra | apoa1rf | 1.9751 | 1.9509 | 0.7243 | 2.73x |
| Apple M3 Ultra | apoa1pme | 1.8133 | 1.8094 | 0.6642 | 2.73x |

## Host environments

- Primary chip: Apple M2, 8 cores (4 performance, 4 efficiency), 10 GPU cores, macOS 27.0 (Build 26A428). Command: `./mini.sh experiments/009-neighbour-list "./harness --repeats 20 --out results-m2.json"`.
- Secondary chip: Apple M3 Ultra, 28 cores, 60 GPU cores, macOS 27.0 (Build 26A428). Command: `./experiments/009-neighbour-list/harness --repeats 20 --out experiments/009-neighbour-list/results-m3ultra.json`.
- SIMD width: `threadExecutionWidth` reports 32 on both Apple M2 and Apple M3 Ultra. The OpenMM kernel define `SIMD_WIDTH` assumes 32.

## Detailed spread and distribution

### Apple M2 (20 repeats)

#### ApoA1 RF
- OpenCL: median 4.6372 ms, min 4.6085 ms, max 4.6730 ms, IQR 0.0153 ms, stddev 0.0137 ms.
- Metal translation (256): median 5.0179 ms, min 4.9848 ms, max 5.0505 ms, IQR 0.0372 ms, stddev 0.0212 ms.
- Metal-native (256): median 1.9897 ms, min 1.9858 ms, max 1.9940 ms, IQR 0.0014 ms, stddev 0.0017 ms.
- OpenCL sequence: median 5.0352 ms, min 4.9874 ms, max 5.2011 ms, IQR 0.0327 ms.
- Metal translation sequence: median 5.4756 ms, min 5.3575 ms, max 5.5390 ms, IQR 0.0996 ms.
- Metal-native sequence: median 2.1749 ms, min 2.1613 ms, max 2.2007 ms, IQR 0.0057 ms.

#### ApoA1 PME
- OpenCL: median 4.1812 ms, min 4.1555 ms, max 5.4460 ms, IQR 0.0467 ms, stddev 0.2755 ms.
- Metal translation (256): median 4.5022 ms, min 4.4796 ms, max 4.6622 ms, IQR 0.0231 ms, stddev 0.0544 ms.
- Metal-native (256): median 1.7715 ms, min 1.7666 ms, max 1.8554 ms, IQR 0.0103 ms, stddev 0.0199 ms.
- OpenCL sequence: median 4.6189 ms, min 4.5886 ms, max 4.7559 ms, IQR 0.0264 ms.
- Metal translation sequence: median 5.0298 ms, min 4.9942 ms, max 5.1197 ms, IQR 0.0315 ms.
- Metal-native sequence: median 1.9796 ms, min 1.9426 ms, max 1.9859 ms, IQR 0.0353 ms.

### Apple M3 Ultra (20 repeats)

#### ApoA1 RF
- OpenCL: median 1.6844 ms, min 1.6830 ms, max 1.7247 ms, IQR 0.0343 ms, stddev 0.0167 ms.
- Metal translation (256): median 1.6831 ms, min 1.6740 ms, max 1.7220 ms, IQR 0.0360 ms, stddev 0.0190 ms.
- Metal-native (256): median 0.5889 ms, min 0.5518 ms, max 0.5962 ms, IQR 0.0077 ms, stddev 0.0142 ms.
- OpenCL sequence: median 1.9751 ms, min 1.9374 ms, max 2.1467 ms, IQR 0.0342 ms.
- Metal translation sequence: median 1.9509 ms, min 1.9466 ms, max 1.9530 ms, IQR 0.0018 ms.
- Metal-native sequence: median 0.7243 ms, min 0.7225 ms, max 0.7263 ms, IQR 0.0014 ms.

#### ApoA1 PME
- OpenCL: median 1.5824 ms, min 1.5594 ms, max 1.9964 ms, IQR 0.0054 ms, stddev 0.0903 ms.
- Metal translation (256): median 1.5868 ms, min 1.5482 ms, max 1.5886 ms, IQR 0.0022 ms, stddev 0.0086 ms.
- Metal-native (256): median 0.5087 ms, min 0.5058 ms, max 0.5116 ms, IQR 0.0014 ms, stddev 0.0014 ms.
- OpenCL sequence: median 1.8133 ms, min 1.8074 ms, max 1.8690 ms, IQR 0.0121 ms.
- Metal translation sequence: median 1.8094 ms, min 1.8076 ms, max 1.8111 ms, IQR 0.0010 ms.
- Metal-native sequence: median 0.6642 ms, min 0.6630 ms, max 0.6667 ms, IQR 0.0011 ms.

## Threadgroup size sweep

We measured median execution times across threadgroup sizes from 32 to 512 threads per threadgroup. Threadgroup memory per block scales with `GROUP_SIZE`:
- Size 32: 1,552 bytes
- Size 64: 3,104 bytes
- Size 128: 6,208 bytes
- Size 256: 12,416 bytes
- Size 512: 24,832 bytes
- Size 1024: 49,664 bytes (compilation fails: exceeds Apple Silicon 32,768 byte hardware threadgroup memory limit)

### Apple M2 threadgroup sweep (median ms)

| Kernel variant | Benchmark | Size 32 | Size 64 | Size 128 | Size 256 | Size 512 | Size 1024 |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| Metal-native | apoa1rf | 1.9695 | 2.0190 | 1.9790 | 1.9890 | 2.1258 | Unsupported (>32 KB) |
| Metal-native | apoa1pme | 1.7403 | 1.7541 | 1.8740 | 1.7742 | 1.8528 | Unsupported (>32 KB) |
| Metal translation | apoa1rf | 4.7913 | 4.8553 | 4.9528 | 5.0198 | 5.1940 | Unsupported (>32 KB) |
| Metal translation | apoa1pme | 4.3752 | 4.4160 | 4.4312 | 4.5161 | 4.7338 | Unsupported (>32 KB) |

### Apple M3 Ultra threadgroup sweep (median ms)

| Kernel variant | Benchmark | Size 32 | Size 64 | Size 128 | Size 256 | Size 512 | Size 1024 |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| Metal-native | apoa1rf | 0.5653 | 0.5673 | 0.5746 | 0.5855 | 1.0905 | Unsupported (>32 KB) |
| Metal-native | apoa1pme | 0.4953 | 0.4927 | 0.4965 | 0.5064 | 0.9288 | Unsupported (>32 KB) |
| Metal translation | apoa1rf | 1.6948 | 1.6977 | 1.7022 | 1.6822 | 2.3386 | Unsupported (>32 KB) |
| Metal translation | apoa1pme | 1.5718 | 1.5649 | 1.5626 | 1.5587 | 2.1711 | Unsupported (>32 KB) |

## Mechanism analysis

1. Straight Metal translation does not improve speed over OpenCL.
   On the M2, straight translation is 8% slower than OpenCL (5.02 ms vs 4.64 ms). On the M3 Ultra, it matches OpenCL exactly (1.68 ms vs 1.68 ms). Translating OpenCL syntax to Metal Shading Language without restructuring kernel logic yields zero gain.

2. SIMD ballot and trailing-zero count eliminate candidate loop overhead.
   In the original OpenCL kernel, candidate interacting blocks write a boolean to a threadgroup array `includeBlockFlags[GROUP_SIZE]`, synchronize threads with a barrier, and then all threads linearly loop through all 32 candidate positions checking the flags. In the Metal-native kernel, `simd_ballot(includeBlock2)` yields a 32-bit active lane mask in one instruction. `ctz(includeMask)` directly returns the next set bit, skipping non-interacting blocks without warp-divergent linear looping.

3. Warp prefix scan in two instructions replaces local memory reduction.
   When testing atoms within an interacting block, the OpenCL kernel writes hit flags to local array `atomCountBuffer`, executes a 5-step ping-pong tree reduction loop across local memory with barriers, and computes prefix ranks. The Metal-native kernel executes:
   ```metal
   uint atomMask = (uint)(ulong)simd_ballot(interacts);
   uint atomRank = popcount(atomMask & ((1u << indexInWarp) - 1u));
   uint atomTotal = popcount(atomMask);
   ```
   This computes lane rank and total count in register space with two instructions, eliminating all threadgroup memory traffic and barrier stalls for atom compaction.

4. Register shuffle broadcast replaces threadgroup scratch memory.
   When flushing full tiles to the output buffer, lane 0 executes an atomic fetch-add on device memory and distributes the allocated tile index using `simd_broadcast(newTileStartIndex, 0u)` rather than storing to local memory and synchronizing.

5. Occupancy cliff at threadgroup size 512 and 1024.
   Threadgroup memory per threadgroup is bounded by 32 KB on Apple Silicon. At size 512, threadgroup memory usage reaches 24.8 KB, restricting the hardware scheduler to one active threadgroup per core and causing a 1.8x slowdown on M3 Ultra. At size 1024, memory requirements reach 49.7 KB, which exceeds the hardware limit and prevents pipeline creation. Sizes 32 and 64 give the highest performance.

## Interaction set verification

All implementations were verified on both benchmarks:
- `apoa1rf`: reference captured run 55,396 tiles, exactly 1,727,984 unique `(block, atom)` interaction pairs.
  - Apple OpenCL: 1,727,984 unique pairs (0 missing, 0 extra).
  - Metal translation: 1,727,984 unique pairs (0 missing, 0 extra).
  - Metal-native: 1,727,984 unique pairs (0 missing, 0 extra).
- `apoa1pme`: reference captured run 43,560 tiles, exactly 1,349,142 unique `(block, atom)` interaction pairs.
  - Apple OpenCL: 1,349,142 unique pairs (0 missing, 0 extra).
  - Metal translation: 1,349,142 unique pairs (0 missing, 0 extra).
  - Metal-native: 1,349,142 unique pairs (0 missing, 0 extra).

Every implementation achieves 100.000% set agreement.

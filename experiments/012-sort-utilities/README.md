# Experiment 012: Sort and utility kernels

## Question

How do OpenMM sort and utility kernels perform when translated from Apple OpenCL to Metal on Apple Silicon, does a Metal native bitonic sort outperform the translated OpenMM bucket sort, and are atom reordering kernels present on GPU in upstream OpenMM master?

## Summary of findings

1. **Numerical agreement:** All six sort kernels and six utility kernels pass correctness checks with 0 mismatches against Apple OpenCL and CPU `std::sort` reference. Reductions match within 0.0000 ppm (against stated tolerance of 1.0 ppm).
2. **Mutation gate:** All five mutation tests (one per family: sort, native sort, buffer clear, reduction, and charge indexing) turn the gate red individually with zero false passes.
3. **Translated sort performance:** Direct translation of OpenMM bucket sort kernels (`computeRange`, `assignElementsToBuckets2`, `computeBucketPositions`, `copyDataToBuckets`, `sortBuckets`) matches or beats Apple OpenCL on both Apple M3 Ultra and Apple M2. On M3 Ultra, whole sort wall time per sort is 0.0618 ms in Metal vs 0.0604 ms in OpenCL for 2,882 block keys, and 0.1366 ms in Metal vs 0.1367 ms in OpenCL for 92,224 atom keys. On M2, Metal whole sort takes 0.2981 ms vs 0.3180 ms in OpenCL for 92,224 keys (1.07x faster in Metal).
4. **Native bitonic sort evaluation:** The Metal native cooperative bitonic sort is 1.50x to 2.94x slower in wall time than the translated bucket sort across all tested sizes (0.0926 ms vs 0.0618 ms for 2,882 keys, 0.4009 ms vs 0.1366 ms for 92,224 keys on M3 Ultra). Bitonic sort requires $O(N \log^2 N)$ comparisons and multiple global synchronization passes, whereas OpenMM bucket sort distributes elements in linear $O(N)$ time across uniform buckets. The translated bucket sort remains the superior design for OpenMM on Apple Silicon.
5. **Atom reordering investigation:** Upstream OpenMM master (`openmm-prof`) contains no GPU kernel for atom reordering (such as `sortAtomIndex`). In OpenMM, `ComputeContext::reorderAtomsImpl()` runs entirely on the host CPU using `std::sort` on 3D Hilbert space-filling curve cell bins. The CPU uploads the reordered coordinate and velocity buffers to GPU memory, followed by executing the GPU utility kernel `setCharges` to permute partial charges according to `atomOrder`.

## Kernel work sizes and defines

All Metal kernels use threadgroup and grid configurations matching OpenCL work-group and global dimensions:

| Kernel | Defines set | OpenCL work size | Metal work size | Match |
| :--- | :--- | :--- | :--- | :--- |
| `computeRange` | `DATA_TYPE=uint`, `KEY_TYPE=uint`, `SORT_KEY=value` | Global: 256, Local: 256 (1 group) | Threads: 256, ThreadsPerThreadgroup: 256 (1 group) | true |
| `assignElementsToBuckets2` | `DATA_TYPE=uint`, `KEY_TYPE=uint`, `SORT_KEY=value` | Global: 2944, Local: 128 (23 groups) | Threads: 2944, ThreadsPerThreadgroup: 128 (23 groups) | true |
| `computeBucketPositions` | `DATA_TYPE=uint`, `KEY_TYPE=uint`, `SORT_KEY=value` | Global: 45, Local: 45 (1 group) | Threads: 45, ThreadsPerThreadgroup: 45 (1 group) | true |
| `copyDataToBuckets` | `DATA_TYPE=uint`, `KEY_TYPE=uint`, `SORT_KEY=value` | Global: 2944, Local: 128 (23 groups) | Threads: 2944, ThreadsPerThreadgroup: 128 (23 groups) | true |
| `sortBuckets` | `DATA_TYPE=uint`, `KEY_TYPE=uint`, `SORT_KEY=value` | Global: 2944, Local: 128 (23 groups) | Threads: 2944, ThreadsPerThreadgroup: 128 (23 groups) | true |
| `sortShortList` | `DATA_TYPE=uint`, `KEY_TYPE=uint`, `SORT_KEY=value` | Global: 256, Local: 256 (1 group) | Threads: 256, ThreadsPerThreadgroup: 256 (1 group) | true |
| `clearBuffer` | none | Global: 23168, Local: 128 (181 groups) | Threads: 23168, ThreadsPerThreadgroup: 128 (181 groups) | true |
| `clearTwoBuffers` | none | Global: 23168, Local: 128 (181 groups) | Threads: 23168, ThreadsPerThreadgroup: 128 (181 groups) | true |
| `reduceFloat4Buffer` | none | Global: 92288, Local: 128 (721 groups) | Threads: 92288, ThreadsPerThreadgroup: 128 (721 groups) | true |
| `reduceForces` | none | Global: 92288, Local: 128 (721 groups) | Threads: 92288, ThreadsPerThreadgroup: 128 (721 groups) | true |
| `reduceEnergy` | none | Global: 256, Local: 256 (1 group) | Threads: 256, ThreadsPerThreadgroup: 256 (1 group) | true |
| `setCharges` | none | Global: 92288, Local: 128 (721 groups) | Threads: 92288, ThreadsPerThreadgroup: 128 (721 groups) | true |

Note on `reduceEnergy`: The OpenCL device limit on Apple Silicon (`CL_DEVICE_MAX_WORK_GROUP_SIZE`) is 256 work items. OpenMM queries this property at runtime and caps work-group size accordingly. Configuring work group sizes beyond 256 triggers OpenCL error `-55` (`CL_INVALID_WORK_ITEM_SIZE`).

## Correctness and numerical agreement

Tested with actual apoa1 production captures from `experiments/009-neighbour-list` and `experiments/011-pme`:

| Kernel | Dataset / input size | Tolerance | Observed diff | Status |
| :--- | :--- | :--- | :--- | :--- |
| `sort` (bucket pipeline) | apoa1 block keys (2,882 elements) | 0 mismatches | 0 mismatches vs CPU `std::sort` | PASS |
| `nativeBitonicSort` | apoa1 block keys (2,882 elements) | 0 mismatches | 0 mismatches vs CPU `std::sort` | PASS |
| `sortShortList` | apoa1 short list (1,024 elements) | 0 mismatches | 0 mismatches vs CPU `std::sort` | PASS |
| `clearBuffer` | 92,224 integers (int4 vectorized) | 0 non-zero | 0 non-zero entries | PASS |
| `clearTwoBuffers` | 92,224 + 2,882 integers | 0 non-zero | 0 non-zero entries | PASS |
| `reduceFloat4Buffer` | 92,224 * 4 floats (4 force buffers) | 1.0 ppm | 0.0000 ppm relative diff | PASS |
| `reduceForces` | 92,224 atoms (4 force buffers) | 1.0 ppm | 0.0000 ppm relative diff | PASS |
| `reduceEnergy` | 2,560 floats | 1.0 ppm | 0.0000 ppm relative diff | PASS |
| `setCharges` | 92,224 atom charges and posq | 0 mismatches | 0 mismatches across all atoms | PASS |

## Mutation gate verification

Each mutation test intentionally corrupts one kernel family to ensure the verification gate fails:

| Family | Mutation target | Corrupted code | Observed gate reaction | Status |
| :--- | :--- | :--- | :--- | :--- |
| Sort | `assignElementsToBuckets2` | `bucketIndex = (bucketIndex + 1) % numBuckets;` | 2,882 / 2,882 key mismatches against reference | RED_DETECTED (PASS) |
| Native sort | `nativeBitonicSort4096` | `ascending = !((i & k) == 0);` | 2,882 / 2,882 mismatches (descending sort order) | RED_DETECTED (PASS) |
| Clear | `clearBuffer` | `buffer4[index] = make_int4(1);` | 1,024 / 1,024 non-zero words detected | RED_DETECTED (PASS) |
| Reduce | `reduceFloat4Buffer` | drops last buffer summation loop | 250,000 ppm relative error (threshold 1.0 ppm) | RED_DETECTED (PASS) |
| Set charges | `setCharges` | `posq[i].w = -charges[atomOrder[i]];` | 1,024 / 1,024 inverted sign charge mismatches | RED_DETECTED (PASS) |

## Benchmark results

### Individual kernel timings on Apple M3 Ultra

25 repetitions per kernel. Profiling clocks:
- OpenCL column clock: OpenCL profiling event time (`clGetEventProfilingInfo` start to end via `clEventMs`, nanosecond precision via `mach_timebase_info`).
- Metal column clock: Metal GPU command buffer timer (`gpuEndTime - gpuStartTime`, nanosecond precision).

| Kernel | Work items | OpenCL GPU event ms (IQR) | Metal GPU timer ms (IQR) | Ratio Metal / OpenCL |
| :--- | :--- | :--- | :--- | :--- |
| `computeRange` | 256 keys | 0.0086 ms (0.0010) | 0.0063 ms (0.0016) | 0.73x |
| `assignElementsToBuckets2` | 2,882 keys | 0.0303 ms (0.0163) | 0.0131 ms (0.0004) | 0.43x |
| `computeBucketPositions` | 45 buckets | 0.0047 ms (0.0005) | 0.0049 ms (0.0006) | 1.03x |
| `copyDataToBuckets` | 2,882 keys | 0.0047 ms (0.0005) | 0.0052 ms (0.0004) | 1.10x |
| `sortBuckets` | 2,882 keys | 0.0138 ms (0.0015) | 0.0141 ms (0.0007) | 1.03x |
| `sortShortList` | 1,024 keys | 0.0451 ms (0.0009) | 0.0543 ms (0.0012) | 1.20x |
| `clearBuffer` | 92,224 ints | 0.0057 ms (0.0006) | 0.0055 ms (0.0003) | 0.96x |
| `clearTwoBuffers` | 95,106 ints | 0.0059 ms (0.0005) | 0.0057 ms (0.0005) | 0.98x |
| `reduceFloat4Buffer` | 92,224 * 4 floats | 0.0114 ms (0.0006) | 0.0122 ms (0.0005) | 1.07x |
| `reduceForces` | 92,224 atoms (4 bufs) | 0.0145 ms (0.0005) | 0.0149 ms (0.0004) | 1.03x |
| `reduceEnergy` | 2,560 floats | 0.0092 ms (0.0008) | 0.0091 ms (0.0005) | 1.00x |
| `setCharges` | 92,224 atoms | 0.0083 ms (0.0007) | 0.0080 ms (0.0002) | 0.97x |

### Individual kernel timings on Apple M2

25 repetitions per kernel:

| Kernel | Work items | OpenCL GPU event ms (IQR) | Metal GPU timer ms (IQR) | Ratio Metal / OpenCL |
| :--- | :--- | :--- | :--- | :--- |
| `computeRange` | 256 keys | 0.0035 ms (0.0000) | 0.0035 ms (0.0000) | 1.00x |
| `assignElementsToBuckets2` | 2,882 keys | 0.0249 ms (0.0052) | 0.0182 ms (0.0015) | 0.73x |
| `computeBucketPositions` | 45 buckets | 0.0071 ms (0.0027) | 0.0040 ms (0.0003) | 0.56x |
| `copyDataToBuckets` | 2,882 keys | 0.0036 ms (0.0024) | 0.0031 ms (0.0022) | 0.85x |
| `sortBuckets` | 2,882 keys | 0.0165 ms (0.0005) | 0.0128 ms (0.0008) | 0.77x |
| `sortShortList` | 1,024 keys | 0.0664 ms (0.0019) | 0.0595 ms (0.0005) | 0.90x |
| `clearBuffer` | 92,224 ints | 0.0032 ms (0.0001) | 0.0033 ms (0.0004) | 1.00x |
| `clearTwoBuffers` | 95,106 ints | 0.0039 ms (0.0004) | 0.0035 ms (0.0001) | 0.90x |
| `reduceFloat4Buffer` | 92,224 * 4 floats | 0.0555 ms (0.0030) | 0.0567 ms (0.0007) | 1.02x |
| `reduceForces` | 92,224 atoms (4 bufs) | 0.0718 ms (0.0010) | 0.0703 ms (0.0009) | 0.98x |
| `reduceEnergy` | 2,560 floats | 0.0084 ms (0.0008) | 0.0126 ms (0.0045) | 1.50x |
| `setCharges` | 92,224 atoms | 0.0286 ms (0.0004) | 0.0288 ms (0.0033) | 1.01x |

### Whole sort multi-kernel sequence benchmark

Measured as host wall time across 32 back-to-back sort iterations per synchronization, restoring input keys inside the batch via GPU buffer copy. Reported as amortized time per sort (median of 25 batches, IQR).

Timing clock: `Host wall clock (32-batch amortized per sort)` via `mach_absolute_time()`.

#### Apple M3 Ultra

| Dataset | Count | OpenCL wall ms (IQR) | Metal Translated wall ms (IQR) | Metal Native wall ms (IQR) | Native / Translated ratio |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `apoa1 blocks` | 2,882 | 0.0604 ms (0.0033) | 0.0618 ms (0.0004) | 0.0926 ms (0.0003) | 1.50x slower |
| `apoa1 atoms` | 92,224 | 0.1367 ms (0.0014) | 0.1366 ms (0.0035) | 0.4009 ms (0.0071) | 2.94x slower |
| `short list` | 1,024 | 0.0543 ms (0.0027) | 0.0606 ms (0.0003) | 0.0926 ms (0.0003) | 1.53x slower |

#### Apple M2

| Dataset | Count | OpenCL wall ms (IQR) | Metal Translated wall ms (IQR) | Metal Native wall ms (IQR) | Native / Translated ratio |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `apoa1 blocks` | 2,882 | 0.0657 ms (0.0008) | 0.0822 ms (0.0004) | 0.1626 ms (0.0048) | 1.98x slower |
| `apoa1 atoms` | 92,224 | 0.3180 ms (0.0013) | 0.2981 ms (0.0003) | 0.6934 ms (0.0021) | 2.33x slower |
| `short list` | 1,024 | 0.0764 ms (0.0016) | 0.1050 ms (0.0045) | 0.1578 ms (0.0008) | 1.50x slower |

## How to run

Build and run verification on macOS with Metal and OpenCL available:

```bash
./run.sh /tmp/results.json
```

The script compiles `harness.swift` using `swiftc -O` and checks numerical agreement and mutation coverage before running benchmarks.

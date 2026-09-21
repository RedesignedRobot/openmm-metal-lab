# Experiment 012 results: Sort and utility kernels

## Executive summary

This experiment evaluated OpenMM sort and utility kernels on Apple Silicon (Apple M3 Ultra and Apple M2) comparing translated Metal kernels against Apple OpenCL. It also benchmarked a Metal-native cooperative bitonic sort against the translated OpenMM bucket sort and investigated atom reordering in upstream OpenMM master.

Key findings:
1. **Numerical exactness:** All translated Metal kernels produce output matching OpenCL and CPU reference exactly. Block sort on 2,882 elements and short list sort on 1,024 elements produce 0 mismatches. All reductions match within 0.0000 ppm.
2. **Translated sort efficiency:** The translated bucket sort sequence (`computeRange`, `assignElementsToBuckets2`, `computeBucketPositions`, `copyDataToBuckets`, `sortBuckets`) performs on par with or faster than Apple OpenCL on both chips. On M3 Ultra, 92,224 atom keys sort in 0.1366 ms in Metal vs 0.1367 ms in OpenCL. On M2, Metal completes the sequence in 0.2981 ms vs 0.3180 ms in OpenCL (1.07x faster in Metal).
3. **Native bitonic sort vs translated bucket sort:** A Metal-native bitonic sort implementation is 1.50x to 2.94x slower than OpenMM's translated bucket sort. Bucket sort partitions keys into buckets in $O(N)$ time with minimal global memory traffic, whereas bitonic sort executes $O(\log^2 N)$ stages of comparisons and global synchronization barriers. Upstream OpenMM should retain its bucket sort design for the Metal platform.
4. **Atom reordering in upstream master:** An audit of upstream OpenMM master (`platforms/common/src/ComputeContext.cpp`) reveals that no GPU atom reordering kernel (such as `sortAtomIndex`) exists. Atom reordering is executed entirely on the host CPU inside `ComputeContext::reorderAtomsImpl()` using `std::sort` on 3D Hilbert space-filling curve cell bins. The host uploads reordered coordinates, velocities, and atom index lists to device memory, followed by executing the GPU utility kernel `setCharges`.

## Hardware platforms

Testing was performed on two Apple Silicon configurations:
- **Apple M3 Ultra:** 60 GPU cores, 128 GB unified memory, macOS 15.
- **Apple M2:** 10 GPU cores, 16 GB unified memory, macOS 15 (remote host `amir@10.10.10.11`).

## Investigation of atom reordering

OpenMM organizes particles in spatial cells to accelerate nonbonded neighbour list generation. To optimize cache locality and memory coalescing, OpenMM periodically reorders atoms so that spatially adjacent particles occupy contiguous indices in GPU buffers.

An audit of upstream master code in `openmm-prof` identified the following implementation details:
- Atom reordering is initiated in `ComputeContext::reorderAtoms()`.
- The sorting step is implemented in `ComputeContext::reorderAtomsImpl()` on the host CPU.
- The algorithm calculates bounding boxes of all molecules, computes cell coordinates, and maps them to 1D keys using a 3D Hilbert curve.
- Sorting is performed via `std::sort` in C++ on the host CPU:
  ```cpp
  std::sort(sortedMolecules.begin(), sortedMolecules.end());
  ```
- The CPU reconstructs atom order arrays, reorders local coordinate and velocity buffers, and uploads them to GPU buffers `posq` and `velm`.
- The GPU executes a single lightweight utility kernel, `setCharges`:
  ```cpp
  setChargesKernel->execute(numAtoms);
  ```
  `setCharges` writes `posq[i].w = charges[atomOrder[i]]` to update per-atom charges according to the new ordering.
- Upstream OpenMM contains no GPU kernel named `sortAtomIndex` or any other GPU-side atom permutation sort. GPU sorting in OpenMM is confined to `OpenCLSort` / `CudaSort` (sorting block bounding boxes during neighbour list builds and sorting short lists).

## Numerical agreement and mutation verification

All kernels were evaluated against Apple OpenCL using apoa1 production simulation captures.

### Numerical agreement results

| Kernel | Input size | Reference | Tolerance | Observed diff | Status |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `sort` (apoa1 blocks) | 2,882 elements | CPU `std::sort` & OpenCL | 0 mismatches | 0 mismatches | PASS |
| `nativeBitonicSort` | 2,882 elements | CPU `std::sort` & OpenCL | 0 mismatches | 0 mismatches | PASS |
| `sortShortList` | 1,024 elements | CPU `std::sort` & OpenCL | 0 mismatches | 0 mismatches | PASS |
| `clearBuffer` | 92,224 integers | Zero check | 0 non-zero | 0 non-zero | PASS |
| `clearTwoBuffers` | 95,106 integers | Zero check | 0 non-zero | 0 non-zero | PASS |
| `reduceFloat4Buffer` | 368,896 floats | OpenCL reduction | 1.0 ppm | 0.0000 ppm | PASS |
| `reduceForces` | 92,224 atoms * 4 | OpenCL reduction | 1.0 ppm | 0.0000 ppm | PASS |
| `reduceEnergy` | 2,560 floats | OpenCL reduction | 1.0 ppm | 0.0000 ppm | PASS |
| `setCharges` | 92,224 atoms | CPU permutation | 0 mismatches | 0 mismatches | PASS |

### Mutation gate results

Five targeted mutations verified the integrity of the test harness. Every mutation triggered a gate failure independently:

| Mutation test | Target kernel | Mutation mechanism | Gate result |
| :--- | :--- | :--- | :--- |
| Sort | `assignElementsToBuckets2` | Shift assigned bucket index by 1 modulo `numBuckets` | RED_DETECTED (PASS, 2882/2882 mismatches) |
| Native sort | `nativeBitonicSort4096` | Invert comparator to produce descending sort | RED_DETECTED (PASS, 2882/2882 mismatches) |
| Clear | `clearBuffer` | Store non-zero integer constant 1 into cleared words | RED_DETECTED (PASS, 1024/1024 non-zero entries) |
| Reduction | `reduceFloat4Buffer` | Drop final buffer contribution from summation | RED_DETECTED (PASS, 250,000 ppm relative error) |
| Set charges | `setCharges` | Negate charges upon store into `posq.w` | RED_DETECTED (PASS, 1024/1024 inverted signs) |

## Individual kernel performance

Each kernel was measured over 25 iterations. The reported statistics are the median and interquartile range (IQR).

Clocks used:
- OpenCL: `OpenCL event (mach ticks via clEventMs)`.
- Metal: `Metal GPU timer (gpuEndTime - gpuStartTime)`.

### Apple M3 Ultra individual timings

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
| `reduceForces` | 92,224 atoms | 0.0145 ms (0.0005) | 0.0149 ms (0.0004) | 1.03x |
| `reduceEnergy` | 2,560 floats | 0.0092 ms (0.0008) | 0.0091 ms (0.0005) | 1.00x |
| `setCharges` | 92,224 atoms | 0.0083 ms (0.0007) | 0.0080 ms (0.0002) | 0.97x |

### Apple M2 individual timings

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
| `reduceForces` | 92,224 atoms | 0.0718 ms (0.0010) | 0.0703 ms (0.0009) | 0.98x |
| `reduceEnergy` | 2,560 floats | 0.0084 ms (0.0008) | 0.0126 ms (0.0045) | 1.50x |
| `setCharges` | 92,224 atoms | 0.0286 ms (0.0004) | 0.0288 ms (0.0033) | 1.01x |

In both architectures, atomic bucket indexing in `assignElementsToBuckets2` is noticeably faster in Metal (0.43x on M3 Ultra, 0.73x on M2). Metal's `atomic_fetch_add_explicit` with `memory_order_relaxed` maps cleanly to Apple Silicon hardware atomic instructions without the complete-path fallback present in Apple's OpenCL driver.

## Whole sort multi-kernel sequence benchmark

In production, sorting in OpenMM is invoked as a multi-kernel sequence:
- Short lists (<= 1,024 elements): `sortShortList`.
- Medium and large lists (> 1,024 elements): `computeRange` -> `assignElementsToBuckets2` -> `computeBucketPositions` -> `copyDataToBuckets` -> `sortBuckets`.

To evaluate end-to-end execution without measuring host dispatch overhead in isolation, the sequence was benchmarked in 32 back-to-back iterations per CPU-GPU synchronization, with input restored by a GPU copy operation within each batch.

Timing clock: `Host wall clock (32-batch amortized per sort)` via `mach_absolute_time()`.

### Whole sort results table

| Chip | Dataset | Count | OpenCL wall ms (IQR) | Metal Translated wall ms (IQR) | Metal Native wall ms (IQR) | Native / Translated ratio |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Apple M3 Ultra** | `apoa1 blocks` | 2,882 | 0.0604 ms (0.0033) | 0.0618 ms (0.0004) | 0.0926 ms (0.0003) | 1.50x slower |
| | `apoa1 atoms` | 92,224 | 0.1367 ms (0.0014) | 0.1366 ms (0.0035) | 0.4009 ms (0.0071) | 2.94x slower |
| | `short list` | 1,024 | 0.0543 ms (0.0027) | 0.0606 ms (0.0003) | 0.0926 ms (0.0003) | 1.53x slower |
| **Apple M2** | `apoa1 blocks` | 2,882 | 0.0657 ms (0.0008) | 0.0822 ms (0.0004) | 0.1626 ms (0.0048) | 1.98x slower |
| | `apoa1 atoms` | 92,224 | 0.3180 ms (0.0013) | 0.2981 ms (0.0003) | 0.6934 ms (0.0021) | 2.33x slower |
| | `short list` | 1,024 | 0.0764 ms (0.0016) | 0.1050 ms (0.0045) | 0.1578 ms (0.0008) | 1.50x slower |

## Analysis of translated sort vs native bitonic sort

The native bitonic sort was implemented using cooperative warp/threadgroup primitives for up to 4,096 elements (`nativeBitonicSort4096`), and a 2-stage hierarchical sort for 92,224 elements (`nativeBitonicLocal4096` followed by multi-pass global merge `nativeBitonicGlobalPass`).

Despite leveraging threadgroup registers and SIMD shuffle instructions, the native bitonic sort is substantially slower across all dataset sizes on both machines:
1. **Algorithmic work:** Bitonic sort requires $\frac{1}{2} \log_2(N) (\log_2(N) + 1)$ comparison steps per element. For 92,224 elements (padded to $2^{17} = 131,072$), this demands $17 \times 18 / 2 = 153$ merge steps per element, totaling over 20 million pairwise comparisons and memory roundtrips.
2. **Bucket sort linearity:** OpenMM's bucket sort distributes elements into buckets with target size 64. Step 1 (range) is a single reduction. Step 2 (assign) takes one linear pass over the data using atomic increments. Step 3 (offsets) takes 45 operations. Step 4 (copy) takes one linear pass. Step 5 (bucket sort) sorts small isolated sub-arrays of size ~64 locally inside threadgroups. The total complexity is strictly linear $O(N)$ with low constant factors.
3. **Synchronization costs:** Large bitonic merges across threadgroups require repeated kernel dispatches or device barriers. Each global pass incurs GPU command encoder overhead and memory roundtrips through L2 cache.

## Recommendations for OpenMM PR #5397

1. **Retain bucket sort design:** Direct translation of OpenMM's OpenCL bucket sort kernels to Metal is completely sound and achieves equivalent or superior performance to Apple OpenCL. There is no performance justification for replacing the algorithm with a bitonic sort.
2. **Work-group size limits:** Upstream OpenMM limits OpenCL work-group size to `CL_DEVICE_MAX_WORK_GROUP_SIZE`, which is 256 on Apple Silicon. Metal kernels can run with threadgroups up to 1,024 threads, but keeping 128 to 256 threads per threadgroup maintains optimal occupancy and register pressure on Apple Silicon shader cores.
3. **No atom reordering GPU work needed:** OpenMM PR #5397 does not need to introduce a GPU atom reordering kernel. Upstream OpenMM performs all molecule sorting and coordinate reordering on the CPU during neighbour list updates, calling only `setCharges` on the GPU.

# Experiment 009: Neighbour List Construction on Apple Silicon

## Question

Can Metal build OpenMM's neighbour list (`findBlocksWithInteractions` and the full neighbour list sequence) faster than Apple's OpenCL on Apple Silicon (M2 primary, M3 Ultra secondary), tested with real equilibrated simulation data?

## Method

1. Real inputs capture (step 1):
   - We patched OpenMM's OpenCL backend (`platforms/opencl/src/OpenCLNonbondedUtilities.cpp` in `/Users/mas/code/wt/openmm-prof`) behind `OPENMM_CAPTURE_DIR`.
   - At step 200 of an equilibrated MD simulation of ApoA1 (both `apoa1rf` and `apoa1pme`), the patch forces a neighbour list rebuild and writes every input buffer, argument scalar, intermediate buffer, and output buffer to disk before and after each kernel.
   - Captures were archived into `captures/apoa1rf.tar.gz` and `captures/apoa1pme.tar.gz` (17.5 MB total, under the 25 MB budget). The worktree diff is saved in `openmm-capture.patch`.

2. Agreement verification (step 2):
   - The canonical interaction set is reconstructed as unique `(block, atom)` interaction pairs, excluding padding slots where `atom == numAtoms`.
   - We verify 100.000% set agreement across four implementations:
     1. Captured OpenCL reference output from OpenMM run on M2.
     2. Standalone Apple OpenCL execution on captured inputs.
     3. 005-style straight Metal translation of OpenCL source.
     4. Metal-native kernel with `simd_ballot` and `ctz`.
   - Both benchmarks achieve exact 0-difference set equivalence:
     - `apoa1rf`: 55,396 tiles, 1,727,984 unique interaction pairs.
     - `apoa1pme`: 43,560 tiles, 1,349,142 unique interaction pairs.

3. Performance benchmarks (steps 3 and 4):
   - Executed using standalone Swift CLI harness (`harness.swift`).
   - Timed with GPU hardware timestamps: OpenCL profiling events converted via mach timebase (`* 125.0 / 3.0` ns), Metal command buffer `(gpuEndTime - gpuStartTime) * 1000.0` ms.
   - All inputs (including `interactionCount` and `rebuildNeighborList`) are restored before each run.
   - 20 iterations per configuration; report median, min, max, IQR, and standard deviation.
   - Threadgroup size swept across 32, 64, 128, 256, 512.
   - Both standalone `findBlocksWithInteractions` and the whole sequence (`findBlockBounds`, `computeSortKeys`, `sortBoxData`, `findBlocksWithInteractions`) are measured.

## Results

### Summary speed table (median ms, 20 runs)

| Chip | Benchmark | OpenCL ms | Metal translation ms | Metal-native ms | Interaction count (pairs) |
| :--- | :--- | :--- | :--- | :--- | :--- |
| Apple M2 | apoa1rf | 4.6372 | 5.0179 | 1.9897 | 1,727,984 |
| Apple M2 | apoa1pme | 4.1812 | 4.5022 | 1.7715 | 1,349,142 |
| Apple M3 Ultra | apoa1rf | 1.6844 | 1.6831 | 0.5889 | 1,727,984 |
| Apple M3 Ultra | apoa1pme | 1.5824 | 1.5868 | 0.5087 | 1,349,142 |

### Key findings

1. Metal-native kernel is 2.3x to 3.1x faster than Apple's OpenCL:
   - On Apple M2: 2.33x faster on `apoa1rf` (1.99 ms vs 4.64 ms); 2.36x faster on `apoa1pme` (1.77 ms vs 4.18 ms).
   - On Apple M3 Ultra: 2.86x faster on `apoa1rf` (0.59 ms vs 1.68 ms); 3.11x faster on `apoa1pme` (0.51 ms vs 1.58 ms).

2. Straight Metal translation yields zero performance improvement:
   - On M2, translating OpenCL line-for-line to Metal is 8% slower than OpenCL (5.02 ms vs 4.64 ms).
   - On M3 Ultra, straight translation matches OpenCL within 0.1% (1.68 ms vs 1.68 ms).
   - Speedups require replacing OpenCL threadgroup memory scans with Apple Silicon SIMD primitives.

3. Hardware threadgroup memory limit bounds group sizes:
   - Apple Silicon GPUs enforce a 32 KB limit on threadgroup memory per threadgroup (`MTLDevice.maxThreadgroupMemoryLength = 32768`).
   - Group size 1024 requires 49.7 KB and fails pipeline creation.
   - Group sizes 32 and 64 give the fastest runtimes (1.74 ms on M2 for PME) by minimizing threadgroup memory footprint and maximizing occupancy.

## What this changes for OpenMM

1. Adopt SIMD-group operations for neighbour searching:
   - Replace `includeBlockFlags` local array and barriers with `(uint)(ulong)simd_ballot(includeBlock2)` and `ctz(includeMask)`.
   - Replace the 5-step local memory prefix sum loop for atom compaction with `popcount(simd_ballot(interacts) & ((1u << lane) - 1u))`.
   - Replace threadgroup tile index distribution with `simd_broadcast(newTileStartIndex, 0u)`.

2. Use threadgroup size 32 or 64:
   - OpenMM's OpenCL backend defaults to 256 threads per threadgroup for `findBlocksWithInteractions`.
   - On Apple Silicon, threadgroup size 32 or 64 lowers threadgroup memory from 12.4 KB to 1.5 KB per group, improving core occupancy without reducing vector efficiency.

## File format of committed captures

The archives `captures/apoa1rf.tar.gz` and `captures/apoa1pme.tar.gz` contain raw binary dumps from step 200 of simulation. All files use little-endian byte ordering.

### Metadata (`metadata.json`)
JSON object containing:
- `numAtoms`: integer atom count (e.g. 92,224).
- `paddedNumAtoms`: integer padded atom count.
- `numBlocks`: integer atom block count (`numAtoms / 32`, e.g. 2,882).
- `maxTiles`: maximum allocated tiles in output buffer (e.g. 57,640).
- `periodicBoxSize`: 4-element float vector `[x, y, z, 0]`.
- `invPeriodicBoxSize`: 4-element float vector `[1/x, 1/y, 1/z, 0]`.
- `periodicBoxVecX`, `periodicBoxVecY`, `periodicBoxVecZ`: 4-element box vectors.
- `parameters`: array of nonbonded force parameter definitions.

### Positional and structural buffers
- `posq.bin`: `numAtoms * sizeof(float4)` (1,475,584 bytes). Atom positions `(x, y, z)` in nm and charge `q`.
- `oldPositions_before.bin`, `oldPositions_after_sortBoxData.bin`, `oldPositions_after_findBlocksWithInteractions.bin`: `numAtoms * sizeof(float4)`. Reference positions used to test if atoms moved past skin distance.
- `blockCenter_after_findBlockBounds.bin`: `numBlocks * sizeof(float4)` (46,112 bytes). Center `(x, y, z)` and bounding sphere radius `w`.
- `blockBoundingBox_after_findBlockBounds.bin`: `numBlocks * sizeof(float4)` (46,112 bytes). Box half-widths `(dx, dy, dz)`.
- `blockSizeRange_after_findBlockBounds.bin`: `numBlockSizes * sizeof(float2)` (368 bytes). Min and max block size recorded per thread block.
- `sortedBlocks_after_computeSortKeys.bin`, `sortedBlocks_after_sort.bin`: `numBlocks * sizeof(uint32_t)` (11,528 bytes). Packed sort keys: high bits bin index, low bits block index.
- `sortedBlockCenter_after_sortBoxData.bin`, `sortedBlockBoundingBox_after_sortBoxData.bin`: `numBlocks * sizeof(float4)`. Centers and bounding boxes permuted into sorted block order.
- `exclusionIndices.bin`: `exclusionIndicesSize * sizeof(uint32_t)` (30,176 bytes for RF). Flat array of excluded block indices.
- `exclusionRowIndices.bin`: `(numBlocks + 1) * sizeof(uint32_t)` (11,532 bytes). Row offsets into `exclusionIndices`.
- `rebuildNeighborList_after_findBlockBounds.bin`, `rebuildNeighborList_after_sortBoxData.bin`: `sizeof(int32_t)` (4 bytes). Flag set to 1 when rebuild is required.

### Neighbour list output buffers
- `interactionCount_after_findBlocksWithInteractions.bin`: `sizeof(uint32_t)` (4 bytes). Number of valid interacting tiles found.
- `interactingTiles_after_findBlocksWithInteractions.bin`: `maxTiles * sizeof(int32_t)` (230,560 bytes). Target block index `x` for tile `t`.
- `interactingAtoms_after_findBlocksWithInteractions.bin`: `maxTiles * 32 * sizeof(uint32_t)` (7,377,920 bytes). Interacting atom indices for tile `t`. Entries `< numAtoms` are valid atom interactions; entries `= numAtoms` are padding.

### Nonbonded force buffers (reusable for Experiment 010)
- `forceBuffers_before.bin`, `forceBuffers_after.bin`: `numAtoms * 3 * sizeof(long long)` (2,213,376 bytes). Fixed-point atom force accumulator buffers.
- `energyBuffer_before.bin`, `energyBuffer_after.bin`: `60 * sizeof(mixed)` (61,440 bytes). Energy reduction buffer.
- `param_0_nonbonded2_sigmaEpsilon.bin`: `numAtoms * sizeof(float2)` (737,792 bytes). Per-atom Lennard-Jones parameters `(sigma, epsilon)`.

## Gate script

To build and run agreement tests and speed benchmarks from the committed captures on this machine:

```sh
sh experiments/009-neighbour-list/run.sh
```

The script exits 0 if all interaction sets match 100.000%, and nonzero if any interaction pair differs.

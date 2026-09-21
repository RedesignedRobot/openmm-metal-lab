#include <metal_stdlib>
using namespace metal;

// Map address space keywords for consistency with OpenMM conventions
#define restrict
#define real float
#define real2 float2
#define real3 float3
#define real4 float4

#ifndef FLT_MAX
#define FLT_MAX 3.40282347e+38f
#endif

// Program-scope builtins from Metal 3.1
uint3 _metal_thread_pos_grid [[thread_position_in_grid]];
uint3 _metal_thread_pos_group [[thread_position_in_threadgroup]];
uint3 _metal_group_pos_grid [[threadgroup_position_in_grid]];
uint3 _metal_threads_grid [[threads_per_grid]];
uint3 _metal_threads_group [[threads_per_threadgroup]];
uint3 _metal_groups_grid [[threadgroups_per_grid]];

#define GLOBAL_ID (_metal_thread_pos_grid.x)
#define GLOBAL_SIZE (_metal_threads_grid.x)
#define LOCAL_ID (_metal_thread_pos_group.x)
#define LOCAL_SIZE (_metal_threads_group.x)

#define get_local_id(x) LOCAL_ID
#define get_local_size(x) LOCAL_SIZE
#define get_global_id(x) GLOBAL_ID
#define get_global_size(x) GLOBAL_SIZE

// BUFFER_SIZE defines the capacity of the warp accumulation buffer (atoms)
#define BUFFER_SIZE 256

/**
 * Metal-native implementation of findBlocksWithInteractions.
 *
 * Optimizations over OpenCL on Apple Silicon:
 * 1. simd_ballot eliminates includeBlockFlags threadgroup array and barriers.
 * 2. ctz iterates only over neighbor blocks that actually interact, skipping empty iterations.
 * 3. simd_ballot + popcount computes warp prefix sums for atom compaction in 2 instructions,
 *    eliminating atomCountBuffer, 5 loop iterations, and ping-pong threadgroup memory barriers.
 * 4. simd_broadcast propagates atomicAdd reserved tile indices across warp lanes without memory writes.
 * 5. Reduced threadgroup memory footprint enables higher occupancy across threadgroup sizes.
 */
kernel void findBlocksWithInteractions_native(
        constant real4& _in_periodicBoxSize [[buffer(0)]],
        constant real4& _in_invPeriodicBoxSize [[buffer(1)]],
        constant real4& _in_periodicBoxVecX [[buffer(2)]],
        constant real4& _in_periodicBoxVecY [[buffer(3)]],
        constant real4& _in_periodicBoxVecZ [[buffer(4)]],
        device unsigned int* restrict interactionCount [[buffer(5)]],
        device int* restrict interactingTiles [[buffer(6)]],
        device unsigned int* restrict interactingAtoms [[buffer(7)]],
        device const real4* restrict posq [[buffer(8)]],
        constant unsigned int& _in_maxTiles [[buffer(9)]],
        constant unsigned int& _in_startBlockIndex [[buffer(10)]],
        constant unsigned int& _in_numBlocks [[buffer(11)]],
        device unsigned int* restrict sortedBlocks [[buffer(12)]],
        device const real4* restrict sortedBlockCenter [[buffer(13)]],
        device const real4* restrict sortedBlockBoundingBox [[buffer(14)]],
        device const unsigned int* restrict exclusionIndices [[buffer(15)]],
        device const unsigned int* restrict exclusionRowIndices [[buffer(16)]],
        device real4* restrict oldPositions [[buffer(17)]],
        device const int* restrict rebuildNeighborList [[buffer(18)]]) {

    real4 periodicBoxSize = _in_periodicBoxSize;
    real4 invPeriodicBoxSize = _in_invPeriodicBoxSize;
    real4 periodicBoxVecX = _in_periodicBoxVecX;
    real4 periodicBoxVecY = _in_periodicBoxVecY;
    real4 periodicBoxVecZ = _in_periodicBoxVecZ;
    unsigned int maxTiles = _in_maxTiles;
    unsigned int startBlockIndex = _in_startBlockIndex;
    unsigned int numBlocks = _in_numBlocks;

    // Check if neighbor list rebuild is required
    if (rebuildNeighborList[0] == 0)
        return;

    // Warp coordinates (Apple Silicon SIMD group is 32 lanes)
    const int indexInWarp = get_local_id(0) % 32;
    const int warpStart = get_local_id(0) - indexInWarp;
    const int warpInGroup = warpStart / 32;
    const int totalWarps = get_global_size(0) / 32;
    const int warpIndex = get_global_id(0) / 32;

    // Threadgroup allocations: only buffer, exclusions, and positions are retained.
    // includeBlockFlags, atomCountBuffer, and workgroupTileIndex are replaced by SIMD-group operations.
    threadgroup int workgroupBuffer[BUFFER_SIZE * (GROUP_SIZE / 32)];
    threadgroup int warpExclusions[MAX_EXCLUSIONS * (GROUP_SIZE / 32)];
    threadgroup real3 posBuffer[GROUP_SIZE];

    threadgroup int* buffer = workgroupBuffer + BUFFER_SIZE * warpInGroup;
    threadgroup int* exclusionsForX = warpExclusions + MAX_EXCLUSIONS * warpInGroup;

    // Loop over target blocks. All 32 threads in each warp process the same block1.
    for (int block1 = startBlockIndex + warpIndex; block1 < startBlockIndex + numBlocks; block1 += totalWarps) {
        int x = sortedBlocks[block1] & BLOCK_INDEX_MASK;
        real4 blockCenterX = sortedBlockCenter[block1];
        real4 blockSizeX = sortedBlockBoundingBox[block1];
        int neighborsInBuffer = 0;
        real3 pos1 = posq[x * TILE_SIZE + indexInWarp].xyz;

#ifdef USE_PERIODIC
        const bool singlePeriodicCopy = (0.5f * periodicBoxSize.x - blockSizeX.x >= PADDED_CUTOFF &&
                                         0.5f * periodicBoxSize.y - blockSizeX.y >= PADDED_CUTOFF &&
                                         0.5f * periodicBoxSize.z - blockSizeX.z >= PADDED_CUTOFF);
        if (singlePeriodicCopy) {
            APPLY_PERIODIC_TO_POS_WITH_CENTER(pos1, blockCenterX);
        }
#endif
        posBuffer[get_local_id(0)] = pos1;

        // Load exclusion list for block x into threadgroup memory
        const int exclusionStart = exclusionRowIndices[x];
        const int exclusionEnd = exclusionRowIndices[x + 1];
        const int numExclusions = exclusionEnd - exclusionStart;
        for (int j = indexInWarp; j < numExclusions; j += 32) {
            exclusionsForX[j] = exclusionIndices[exclusionStart + j];
        }
        simdgroup_barrier(mem_flags::mem_threadgroup);

        // Search for interacting neighbor blocks (32 blocks compared in parallel per step)
        for (int block2Base = block1 + 1; block2Base < NUM_BLOCKS; block2Base += 32) {
            int block2 = block2Base + indexInWarp;
            bool includeBlock2 = (block2 < NUM_BLOCKS);
            if (includeBlock2) {
                real4 blockCenterY = sortedBlockCenter[block2];
                real4 blockSizeY = sortedBlockBoundingBox[block2];
                real4 blockDelta = blockCenterX - blockCenterY;
#ifdef USE_PERIODIC
                APPLY_PERIODIC_TO_DELTA(blockDelta);
#endif
                includeBlock2 &= (blockDelta.x * blockDelta.x + blockDelta.y * blockDelta.y + blockDelta.z * blockDelta.z <
                                  (PADDED_CUTOFF + blockCenterX.w + blockCenterY.w) * (PADDED_CUTOFF + blockCenterX.w + blockCenterY.w));
                blockDelta.x = max((real) 0, fabs(blockDelta.x) - blockSizeX.x - blockSizeY.x);
                blockDelta.y = max((real) 0, fabs(blockDelta.y) - blockSizeX.y - blockSizeY.y);
                blockDelta.z = max((real) 0, fabs(blockDelta.z) - blockSizeX.z - blockSizeY.z);
                includeBlock2 &= (blockDelta.x * blockDelta.x + blockDelta.y * blockDelta.y + blockDelta.z * blockDelta.z < PADDED_CUTOFF_SQUARED);
#ifdef TRICLINIC
                if (periodicBoxSize.z / 2 - blockSizeX.z - blockSizeY.z < PADDED_CUTOFF ||
                    periodicBoxSize.y / 2 - blockSizeX.y - blockSizeY.y < PADDED_CUTOFF)
                    includeBlock2 = true;
#endif
                if (includeBlock2) {
                    int y = sortedBlocks[block2] & BLOCK_INDEX_MASK;
                    for (int k = 0; k < numExclusions; k++) {
                        includeBlock2 &= (exclusionsForX[k] != y);
                    }
                }
            }

            // SIMD ballot across the 32 threads forms a 32-bit bitmask of candidate blocks.
            // This replaces writing to local memory includeBlockFlags and calling SYNC_WARPS.
            uint includeMask = (uint)(ulong)simd_ballot(includeBlock2);

            // Iterate over only the set bits in includeMask using ctz (count trailing zeros).
            // This skips non-interacting blocks without warp-divergent linear scanning.
            while (includeMask != 0) {
                int i = ctz(includeMask);
                includeMask &= (includeMask - 1u); // Clear lowest set bit

                int y = sortedBlocks[block2Base + i] & BLOCK_INDEX_MASK;
                int atom2 = y * TILE_SIZE + indexInWarp;
                real3 pos2 = posq[atom2].xyz;

#ifdef USE_PERIODIC
                if (singlePeriodicCopy) {
                    APPLY_PERIODIC_TO_POS_WITH_CENTER(pos2, blockCenterX);
                }
#endif
                bool interacts = false;
                if (atom2 < NUM_ATOMS) {
#ifdef USE_PERIODIC
                    if (!singlePeriodicCopy) {
                        for (int j = 0; j < TILE_SIZE; j++) {
                            real3 delta = pos2 - posBuffer[warpStart + j];
                            APPLY_PERIODIC_TO_DELTA(delta);
                            interacts |= (delta.x * delta.x + delta.y * delta.y + delta.z * delta.z < PADDED_CUTOFF_SQUARED);
                        }
                    } else {
#endif
                        for (int j = 0; j < TILE_SIZE; j++) {
                            real3 delta = pos2 - posBuffer[warpStart + j];
                            interacts |= (delta.x * delta.x + delta.y * delta.y + delta.z * delta.z < PADDED_CUTOFF_SQUARED);
                        }
#ifdef USE_PERIODIC
                    }
#endif
                }

                // SIMD compaction: gather interacting atom flags across 32 threads into a bitmask.
                // The lane offset (rank) is the popcount of lower bits; total count is full popcount.
                // This eliminates the 5-step threadgroup memory prefix sum loop.
                uint atomMask = (uint)(ulong)simd_ballot(interacts);
                uint atomRank = popcount(atomMask & ((1u << indexInWarp) - 1u));
                uint atomTotal = popcount(atomMask);

                if (interacts) {
                    buffer[neighborsInBuffer + atomRank] = atom2;
                }
                neighborsInBuffer += atomTotal;

                // When buffer holds more than BUFFER_SIZE - TILE_SIZE (224) atoms, flush full tiles
                if (neighborsInBuffer > BUFFER_SIZE - TILE_SIZE) {
                    unsigned int tilesToStore = neighborsInBuffer / TILE_SIZE;
                    unsigned int newTileStartIndex = 0;
                    if (indexInWarp == 0) {
                        // Lane 0 claims tile slots with an atomic add in device memory
                        newTileStartIndex = atomic_fetch_add_explicit(
                            (device atomic_uint*)interactionCount,
                            tilesToStore,
                            memory_order_relaxed);
                    }
                    // Broadcast newTileStartIndex to all lanes via SIMD group shuffle
                    newTileStartIndex = simd_broadcast(newTileStartIndex, 0u);

                    if (newTileStartIndex + tilesToStore <= maxTiles) {
                        if (indexInWarp < (int)tilesToStore) {
                            interactingTiles[newTileStartIndex + indexInWarp] = x;
                        }
                        for (int j = 0; j < (int)tilesToStore; j++) {
                            interactingAtoms[(newTileStartIndex + j) * TILE_SIZE + indexInWarp] =
                                buffer[indexInWarp + j * TILE_SIZE];
                        }
                    }
                    if (indexInWarp + TILE_SIZE * (int)tilesToStore < BUFFER_SIZE) {
                        buffer[indexInWarp] = buffer[indexInWarp + TILE_SIZE * tilesToStore];
                    }
                    neighborsInBuffer -= TILE_SIZE * tilesToStore;
                }
            }
        }

        // Flush any remaining interacting atoms in buffer at the end of block 1
        if (neighborsInBuffer > 0) {
            unsigned int tilesToStore = (neighborsInBuffer + TILE_SIZE - 1) / TILE_SIZE;
            unsigned int newTileStartIndex = 0;
            if (indexInWarp == 0) {
                newTileStartIndex = atomic_fetch_add_explicit(
                    (device atomic_uint*)interactionCount,
                    tilesToStore,
                    memory_order_relaxed);
            }
            newTileStartIndex = simd_broadcast(newTileStartIndex, 0u);

            if (newTileStartIndex + tilesToStore <= maxTiles) {
                if (indexInWarp < (int)tilesToStore) {
                    interactingTiles[newTileStartIndex + indexInWarp] = x;
                }
                for (int j = 0; j < (int)tilesToStore; j++) {
                    int atomIndex = indexInWarp + j * TILE_SIZE;
                    interactingAtoms[(newTileStartIndex + j) * TILE_SIZE + indexInWarp] =
                        (atomIndex < neighborsInBuffer ? buffer[atomIndex] : NUM_ATOMS);
                }
            }
        }
    }

    // Record reference positions for neighbor list invalidation checks
    for (int i = get_global_id(0); i < NUM_ATOMS; i += get_global_size(0)) {
        oldPositions[i] = posq[i];
    }
}

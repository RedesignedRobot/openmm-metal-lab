#include <metal_stdlib>
using namespace metal;

// OpenMM Metal Native Implementation of computeNonbonded with Exclusion Optimizations
// Supports Reaction Field (RF) and Particle Mesh Ewald (PME) direct space.
// Formulations:
// - Baseline: circular SIMD shuffle in loop 1
// - Formulation 1 (FORMULATION_OPENCL_LOCAL): OpenCL loop structure verbatim with threadgroup memory
// - Formulation 2 (FORMULATION_SEPARATE_KERNEL): computeNonbonded_exclusions dispatched on own grid
// - Formulation 3 (FORMULATION_MASKED): branch-free masked accumulation
// - Formulation 4 (FORMULATION_UNROLLED_2 / FORMULATION_UNROLLED_4): tile-size specialised unrolling
// - Writeback Alternative (WRITEBACK_LOOP1_ACC): force accumulation across consecutive tiles in loop 1
// - Mutation flags: MUTATE_VARIANT_A, MUTATE_VARIANT_B, MUTATE_ENERGY,
//                   MUTATE_F1_LOCAL, MUTATE_F2_SEPARATE, MUTATE_F3_MASK,
//                   MUTATE_F4_UNROLL, MUTATE_WB_ACC

#define TILE_SIZE 32
#define NUM_ATOMS 92224
#define PADDED_NUM_ATOMS 92224
#define FIRST_EXCLUSION_TILE 0
#define LAST_EXCLUSION_TILE 5213
#if defined(USE_PME)
#define CUTOFF_0_SQUARED 8.10000000e-01f
#define MAX_CUTOFF 9.00000000e-01f
#else
#define CUTOFF_0_SQUARED 1.00000000e+00f
#define MAX_CUTOFF 1.00000000e+00f
#endif

inline long realToFixedPoint(float x) {
#if defined(ABLATION_B_NO_FIXED_POINT)
    return (long) x;
#else
    return (long)(x * 4294967296.0f);
#endif
}

// 64-bit atomic placeholder: split-word addition with carry propagation.
inline ulong atom_add_split64(volatile device ulong* p, ulong val) {
    volatile device atomic_uint* word = (volatile device atomic_uint*) p;
    uint lower = (uint) val;
    uint upper = (uint) (val >> 32);
    uint result = atomic_fetch_add_explicit(&word[0], lower, memory_order_relaxed);
#if defined(WRITEBACK_OPTIMIZED_CARRY)
    uint carry = (lower + result < lower) ? 1 : 0;
#else
    int carry = ((ulong) lower + (ulong) result >= 0x100000000ULL ? 1 : 0);
#endif
    upper += carry;
    if (upper != 0)
        atomic_fetch_add_explicit(&word[1], upper, memory_order_relaxed);
    return 0;
}

#if defined(ABLATION_A_NO_ATOMIC)
#define ATOMIC_ADD(dest, value) forceBuffers[thread_pos_grid.x] = (value)
#else
#define ATOMIC_ADD(dest, value) atom_add_split64(dest, value)
#endif

#define APPLY_PERIODIC_TO_DELTA(delta) \
    delta.xyz -= floor(delta.xyz * invPeriodicBoxSize.xyz + 0.5f) * periodicBoxSize.xyz;

#define APPLY_PERIODIC_TO_POS_WITH_CENTER(pos, center) \
    { \
    pos.x -= floor((pos.x - center.x) * invPeriodicBoxSize.x + 0.5f) * periodicBoxSize.x; \
    pos.y -= floor((pos.y - center.y) * invPeriodicBoxSize.y + 0.5f) * periodicBoxSize.y; \
    pos.z -= floor((pos.z - center.z) * invPeriodicBoxSize.z + 0.5f) * periodicBoxSize.z; \
    }

// Interaction calculation function
inline void computePairInteraction(
    float4 posq1, float2 params1,
    float4 posq2, float2 params2,
    float4 delta, float r2, float invR, float r,
    bool isExcluded,
    thread float& tempForce,
    thread float& tempEnergy,
    thread float& dEdR)
{
#if defined(ABLATION_E_MEMORY_ONLY)
    tempForce = 0.001f;
    tempEnergy = 0.001f;
    dEdR = 0.001f;
    return;
#endif
    unsigned int includeInteraction = (!isExcluded && r2 < CUTOFF_0_SQUARED);
    tempForce = 0.0f;
    float sig = params1.x + params2.x;
    float sig2 = invR * sig;
    sig2 *= sig2;
    float sig6 = sig2 * sig2 * sig2;
    float eps = params1.y * params2.y;
    float epssig6 = sig6 * eps;
    tempForce = epssig6 * (12.0f * sig6 - 6.0f);
    float ljEnergy = includeInteraction ? epssig6 * (sig6 - 1.0f) : 0.0f;

#if defined(USE_PME)
    // PME direct space interaction (ApoA1 PME)
    const float alphaR = 2.92028987e+00f * r;
    const float expAlphaRSqr = exp(-alphaR * alphaR);
    const float prefactor = 1.38935458e+02f * posq1.w * posq2.w * invR;
    const float t = 1.0f / (1.0f + 0.3275911f * alphaR);
    const float erfcAlphaR = (0.254829592f + (-0.284496736f + (1.421413741f + (-1.453152027f + 1.061405429f * t) * t) * t) * t) * t * expAlphaRSqr;
    tempForce += prefactor * (erfcAlphaR + alphaR * expAlphaRSqr * 1.12837917e+00f);
    tempEnergy += includeInteraction ? ljEnergy + prefactor * erfcAlphaR : 0.0f;
#else
    // Reaction field interaction (ApoA1 RF)
    tempEnergy += ljEnergy;
    const float prefactor = 1.38935458e+02f * posq1.w * posq2.w;
    tempForce += prefactor * (invR - 2.0f * 4.90482234e-01f * r2);
    tempEnergy += includeInteraction ? prefactor * (invR + 4.90482234e-01f * r2 - 1.49048223e+00f) : 0.0f;
#endif

    dEdR += includeInteraction ? tempForce * invR * invR : 0.0f;
}

// Branch-free masked interaction function
inline void computePairInteractionMasked(
    float4 posq1, float2 params1,
    float4 posq2, float2 params2,
    float4 delta, float r2,
    bool isExcluded,
    thread float& tempForce,
    thread float& tempEnergy,
    thread float& dEdR)
{
    tempForce = 0.0f;
    tempEnergy = 0.0f;
    dEdR = 0.0f;
    if (isExcluded || r2 >= CUTOFF_0_SQUARED)
        return;

    float invR = rsqrt(r2);
    float r = r2 * invR;

    float sig = params1.x + params2.x;
    float sig2 = invR * sig;
    sig2 *= sig2;
    float sig6 = sig2 * sig2 * sig2;
    float eps = params1.y * params2.y;
    float epssig6 = sig6 * eps;
    tempForce = epssig6 * (12.0f * sig6 - 6.0f);
    float ljEnergy = epssig6 * (sig6 - 1.0f);

#if defined(USE_PME)
    const float alphaR = 2.92028987e+00f * r;
    const float expAlphaRSqr = exp(-alphaR * alphaR);
    const float prefactor = 1.38935458e+02f * posq1.w * posq2.w * invR;
    const float t = 1.0f / (1.0f + 0.3275911f * alphaR);
    const float erfcAlphaR = (0.254829592f + (-0.284496736f + (1.421413741f + (-1.453152027f + 1.061405429f * t) * t) * t) * t) * t * expAlphaRSqr;
    tempForce += prefactor * (erfcAlphaR + alphaR * expAlphaRSqr * 1.12837917e+00f);
    tempEnergy += ljEnergy + prefactor * erfcAlphaR;
#else
    tempEnergy += ljEnergy;
    const float prefactor = 1.38935458e+02f * posq1.w * posq2.w;
    tempForce += prefactor * (invR - 2.0f * 4.90482234e-01f * r2);
    tempEnergy += prefactor * (invR + 4.90482234e-01f * r2 - 1.49048223e+00f);
#endif

#if defined(MUTATE_F3_MASK)
    tempForce *= 1.05f;
#endif

    dEdR = tempForce * invR * invR;
}

// ---------------------------------------------------------------------------
// Separate Exclusion Tiles Kernel (Formulation 2)
// Dispatched on a grid of LAST_EXCLUSION_TILE threadgroups of 32 threads.
// Each threadgroup handles exactly one exclusion tile.
// ---------------------------------------------------------------------------
kernel void computeNonbonded_exclusions(
    device ulong* forceBuffers [[buffer(0)]],
    device float* energyBuffer [[buffer(1)]],
    device const float4* posq [[buffer(2)]],
    device const uint* exclusions [[buffer(3)]],
    device const int2* exclusionTiles [[buffer(4)]],
    constant float4& periodicBoxSize [[buffer(9)]],
    constant float4& invPeriodicBoxSize [[buffer(10)]],
    device const float2* global_nonbonded2_sigmaEpsilon [[buffer(18)]],
    uint3 threadgroup_pos_grid [[threadgroup_position_in_grid]],
    uint3 thread_pos_grid [[thread_position_in_grid]],
    uint tgx [[thread_index_in_simdgroup]])
{
    const uint pos = threadgroup_pos_grid.x;
    if (pos >= LAST_EXCLUSION_TILE)
        return;

    const int2 tileIndices = exclusionTiles[pos];
    const uint x = tileIndices.x;
    const uint y = tileIndices.y;
    float4 force = 0.0f;
    uint atom1 = x * TILE_SIZE + tgx;
    float4 posq1 = posq[atom1];
    float2 params1 = global_nonbonded2_sigmaEpsilon[atom1];
    uint excl = exclusions[pos * TILE_SIZE + tgx];
    float energy = 0.0f;

    if (x == y) {
        // Diagonal tile
        for (uint j = 0; j < TILE_SIZE; j++) {
            float4 posq2 = simd_shuffle(posq1, (ushort)j);
            float2 params2 = simd_shuffle(params1, (ushort)j);
            uint atom2 = y * TILE_SIZE + j;
            bool isIncluded = (atom1 < NUM_ATOMS && atom2 < NUM_ATOMS && (excl & 0x1));
            if (isIncluded) {
                float4 delta = float4(posq2.xyz - posq1.xyz, 0.0f);
                APPLY_PERIODIC_TO_DELTA(delta)
                float r2 = delta.x * delta.x + delta.y * delta.y + delta.z * delta.z;
                float tempEnergy = 0.0f;
                float tempForce = 0.0f;
                float dEdR = 0.0f;
                computePairInteractionMasked(posq1, params1, posq2, params2, delta, r2, false, tempForce, tempEnergy, dEdR);
                energy += 0.5f * tempEnergy;
                force.xyz -= delta.xyz * dEdR;
            }
            excl >>= 1;
        }
#if defined(MUTATE_F2_SEPARATE)
        force.x *= 1.05f;
#endif
#if !defined(EXCLUDE_FORCES)
        uint offset = x * TILE_SIZE + tgx;
        ATOMIC_ADD(&forceBuffers[offset], (ulong) realToFixedPoint(force.x));
        ATOMIC_ADD(&forceBuffers[offset + PADDED_NUM_ATOMS], (ulong) realToFixedPoint(force.y));
        ATOMIC_ADD(&forceBuffers[offset + 2 * PADDED_NUM_ATOMS], (ulong) realToFixedPoint(force.z));
#endif
    } else {
        // Off-diagonal tile: circular SIMD shuffle rotation
        uint j_idx = y * TILE_SIZE + tgx;
        float4 shflPosq = posq[j_idx];
        float2 shflParams = global_nonbonded2_sigmaEpsilon[j_idx];
        float3 shflForce = float3(0.0f);
        excl = (excl >> tgx) | (excl << (TILE_SIZE - tgx));

        for (uint j = 0; j < TILE_SIZE; j++) {
            float4 posq2 = shflPosq;
            float2 params2 = shflParams;
            uint atom2 = y * TILE_SIZE + ((tgx + j) & 31);
            bool isIncluded = (atom1 < NUM_ATOMS && atom2 < NUM_ATOMS && (excl & 0x1));
            if (isIncluded) {
                float4 delta = float4(posq2.xyz - posq1.xyz, 0.0f);
                APPLY_PERIODIC_TO_DELTA(delta)
                float r2 = delta.x * delta.x + delta.y * delta.y + delta.z * delta.z;
                float tempEnergy = 0.0f;
                float tempForce = 0.0f;
                float dEdR = 0.0f;
                computePairInteractionMasked(posq1, params1, posq2, params2, delta, r2, false, tempForce, tempEnergy, dEdR);
                energy += tempEnergy;
                force.xyz -= delta.xyz * dEdR;
                shflForce += delta.xyz * dEdR;
            }
            excl >>= 1;

            shflPosq = simd_shuffle_and_fill_down(shflPosq, shflPosq, 1);
            shflParams = simd_shuffle_and_fill_down(shflParams, shflParams, 1);
            shflForce = simd_shuffle_and_fill_down(shflForce, shflForce, 1);
        }
#if defined(MUTATE_F2_SEPARATE)
        force.x *= 1.05f;
#endif
#if !defined(EXCLUDE_FORCES)
        uint offset1 = x * TILE_SIZE + tgx;
        ATOMIC_ADD(&forceBuffers[offset1], (ulong) realToFixedPoint(force.x));
        ATOMIC_ADD(&forceBuffers[offset1 + PADDED_NUM_ATOMS], (ulong) realToFixedPoint(force.y));
        ATOMIC_ADD(&forceBuffers[offset1 + 2 * PADDED_NUM_ATOMS], (ulong) realToFixedPoint(force.z));

        uint offset2 = y * TILE_SIZE + tgx;
        ATOMIC_ADD(&forceBuffers[offset2], (ulong) realToFixedPoint(shflForce.x));
        ATOMIC_ADD(&forceBuffers[offset2 + PADDED_NUM_ATOMS], (ulong) realToFixedPoint(shflForce.y));
        ATOMIC_ADD(&forceBuffers[offset2 + 2 * PADDED_NUM_ATOMS], (ulong) realToFixedPoint(shflForce.z));
#endif
    }

#if defined(INCLUDE_ENERGY)
    energyBuffer[thread_pos_grid.x] = energy;
#endif
}

// ---------------------------------------------------------------------------
// Main computeNonbonded Kernel
// ---------------------------------------------------------------------------
kernel void computeNonbonded(
    device ulong* forceBuffers [[buffer(0)]],
    device float* energyBuffer [[buffer(1)]],
    device const float4* posq [[buffer(2)]],
    device const uint* exclusions [[buffer(3)]],
    device const int2* exclusionTiles [[buffer(4)]],
    constant uint& startTileIndex [[buffer(5)]],
    constant ulong& numTileIndices [[buffer(6)]],
    device const int* tiles [[buffer(7)]],
    device const uint* interactionCount [[buffer(8)]],
    constant float4& periodicBoxSize [[buffer(9)]],
    constant float4& invPeriodicBoxSize [[buffer(10)]],
    constant float4& periodicBoxVecX [[buffer(11)]],
    constant float4& periodicBoxVecY [[buffer(12)]],
    constant float4& periodicBoxVecZ [[buffer(13)]],
    constant uint& maxTiles [[buffer(14)]],
    device const float4* blockCenter [[buffer(15)]],
    device const float4* blockSize [[buffer(16)]],
    device const int* interactingAtoms [[buffer(17)]],
    device const float2* global_nonbonded2_sigmaEpsilon [[buffer(18)]],
    uint3 thread_pos_grid [[thread_position_in_grid]],
    uint3 thread_pos_group [[thread_position_in_threadgroup]],
    uint3 threads_grid [[threads_per_grid]],
    uint tgx [[thread_index_in_simdgroup]])
{
    const uint totalWarps = threads_grid.x / TILE_SIZE;
    const uint warp = thread_pos_grid.x / TILE_SIZE;
    float energy = 0.0f;

#if defined(FORMULATION_OPENCL_LOCAL)
    threadgroup float4 localPosq[256];
    threadgroup float2 localParams[256];
    threadgroup float3 localF[256];
    const uint tbx = (thread_pos_group.x / 32) * 32;
    const uint localAtomIndex = tbx + tgx;
#endif

    // Loop 1: Exclusion tiles (diagonal and off-diagonal with exclusions)
#if defined(ABLATION_C_NO_EXCLUSIONS) || defined(FORMULATION_SEPARATE_KERNEL)
    // Skipped: exclusion tiles removed or handled by separate kernel
#else
    const uint firstExclusionTile = FIRST_EXCLUSION_TILE + warp * (LAST_EXCLUSION_TILE - FIRST_EXCLUSION_TILE) / totalWarps;
    const uint lastExclusionTile = FIRST_EXCLUSION_TILE + (warp + 1) * (LAST_EXCLUSION_TILE - FIRST_EXCLUSION_TILE) / totalWarps;

#if defined(WRITEBACK_LOOP1_ACC)
    int currentExclX = -1;
    long excl_atom1_acc_x = 0;
    long excl_atom1_acc_y = 0;
    long excl_atom1_acc_z = 0;
#endif

    for (uint pos = firstExclusionTile; pos < lastExclusionTile; pos++) {
        const int2 tileIndices = exclusionTiles[pos];
        const uint x = tileIndices.x;
        const uint y = tileIndices.y;
        float4 force = 0.0f;
        uint atom1 = x * TILE_SIZE + tgx;
        float4 posq1 = posq[atom1];
        float2 params1 = global_nonbonded2_sigmaEpsilon[atom1];
        uint excl = exclusions[pos * TILE_SIZE + tgx];

#if defined(FORMULATION_OPENCL_LOCAL)
        // -------------------------------------------------------------------
        // Formulation 1: Verbatim OpenCL loop structure with threadgroup mem
        // -------------------------------------------------------------------
        if (x == y) {
            localPosq[localAtomIndex] = posq1;
            localParams[localAtomIndex] = params1;
            simdgroup_barrier(mem_flags::mem_threadgroup);

            for (uint j = 0; j < TILE_SIZE; j++) {
                float4 posq2 = localPosq[tbx + j];
                float2 params2 = localParams[tbx + j];
                float4 delta = float4(posq2.xyz - posq1.xyz, 0.0f);
                APPLY_PERIODIC_TO_DELTA(delta)
                float r2 = delta.x * delta.x + delta.y * delta.y + delta.z * delta.z;
                float invR = rsqrt(r2);
                float r = r2 * invR;
                uint atom2 = y * TILE_SIZE + j;
                bool isExcluded = (atom1 >= NUM_ATOMS || atom2 >= NUM_ATOMS || !(excl & 0x1));
                float tempEnergy = 0.0f;
                float tempForce = 0.0f;
                float dEdR = 0.0f;
                computePairInteraction(posq1, params1, posq2, params2, delta, r2, invR, r, isExcluded, tempForce, tempEnergy, dEdR);
                energy += 0.5f * tempEnergy;
                force.xyz -= delta.xyz * dEdR;
                excl >>= 1;
            }
#if defined(MUTATE_F1_LOCAL)
            force.x *= 1.05f;
#endif
#if !defined(EXCLUDE_FORCES)
            uint offset = x * TILE_SIZE + tgx;
            ATOMIC_ADD(&forceBuffers[offset], (ulong) realToFixedPoint(force.x));
            ATOMIC_ADD(&forceBuffers[offset + PADDED_NUM_ATOMS], (ulong) realToFixedPoint(force.y));
            ATOMIC_ADD(&forceBuffers[offset + 2 * PADDED_NUM_ATOMS], (ulong) realToFixedPoint(force.z));
#endif
        } else {
            uint j_idx = y * TILE_SIZE + tgx;
            localPosq[localAtomIndex] = posq[j_idx];
            localParams[localAtomIndex] = global_nonbonded2_sigmaEpsilon[j_idx];
            localF[localAtomIndex] = float3(0.0f);
            simdgroup_barrier(mem_flags::mem_threadgroup);

            excl = (excl >> tgx) | (excl << (TILE_SIZE - tgx));
            uint tj = tgx;
            for (uint j = 0; j < TILE_SIZE; j++) {
                float4 posq2 = localPosq[tbx + tj];
                float2 params2 = localParams[tbx + tj];
                float4 delta = float4(posq2.xyz - posq1.xyz, 0.0f);
                APPLY_PERIODIC_TO_DELTA(delta)
                float r2 = delta.x * delta.x + delta.y * delta.y + delta.z * delta.z;
                float invR = rsqrt(r2);
                float r = r2 * invR;
                uint atom2 = y * TILE_SIZE + tj;
                bool isExcluded = (atom1 >= NUM_ATOMS || atom2 >= NUM_ATOMS || !(excl & 0x1));
                float tempEnergy = 0.0f;
                float tempForce = 0.0f;
                float dEdR = 0.0f;
                computePairInteraction(posq1, params1, posq2, params2, delta, r2, invR, r, isExcluded, tempForce, tempEnergy, dEdR);
                energy += tempEnergy;
                delta.xyz *= dEdR;
                force.xyz -= delta.xyz;
                localF[tbx + tj] += delta.xyz;
                excl >>= 1;
                tj = (tj + 1) & (TILE_SIZE - 1);
            }
            simdgroup_barrier(mem_flags::mem_threadgroup);
#if defined(MUTATE_F1_LOCAL)
            force.x *= 1.05f;
#endif
#if !defined(EXCLUDE_FORCES)
            uint offset1 = x * TILE_SIZE + tgx;
            ATOMIC_ADD(&forceBuffers[offset1], (ulong) realToFixedPoint(force.x));
            ATOMIC_ADD(&forceBuffers[offset1 + PADDED_NUM_ATOMS], (ulong) realToFixedPoint(force.y));
            ATOMIC_ADD(&forceBuffers[offset1 + 2 * PADDED_NUM_ATOMS], (ulong) realToFixedPoint(force.z));

            uint offset2 = y * TILE_SIZE + tgx;
            float3 shflForce = localF[localAtomIndex];
            ATOMIC_ADD(&forceBuffers[offset2], (ulong) realToFixedPoint(shflForce.x));
            ATOMIC_ADD(&forceBuffers[offset2 + PADDED_NUM_ATOMS], (ulong) realToFixedPoint(shflForce.y));
            ATOMIC_ADD(&forceBuffers[offset2 + 2 * PADDED_NUM_ATOMS], (ulong) realToFixedPoint(shflForce.z));
#endif
        }

#else
        // -------------------------------------------------------------------
        // SIMD-shuffle based formulations (Baseline, Masked, Unrolled)
        // -------------------------------------------------------------------
        if (x == y) {
            // Diagonal tile: broadcast atom2 from each lane j in turn
#if defined(FORMULATION_UNROLLED_4)
            #pragma unroll 4
#elif defined(FORMULATION_UNROLLED_2)
            #pragma unroll 2
#endif
            for (uint j = 0; j < TILE_SIZE; j++) {
                float4 posq2 = simd_shuffle(posq1, (ushort)j);
                float2 params2 = simd_shuffle(params1, (ushort)j);
                uint atom2 = y * TILE_SIZE + j;

#if defined(FORMULATION_MASKED)
                bool isIncluded = (atom1 < NUM_ATOMS && atom2 < NUM_ATOMS && (excl & 0x1));
                if (isIncluded) {
                    float4 delta = float4(posq2.xyz - posq1.xyz, 0.0f);
                    APPLY_PERIODIC_TO_DELTA(delta)
                    float r2 = delta.x * delta.x + delta.y * delta.y + delta.z * delta.z;
                    float tempEnergy = 0.0f;
                    float tempForce = 0.0f;
                    float dEdR = 0.0f;
                    computePairInteractionMasked(posq1, params1, posq2, params2, delta, r2, false, tempForce, tempEnergy, dEdR);
                    energy += 0.5f * tempEnergy;
                    force.xyz -= delta.xyz * dEdR;
                }
#else
                float4 delta = float4(posq2.xyz - posq1.xyz, 0.0f);
                APPLY_PERIODIC_TO_DELTA(delta)
                float r2 = delta.x * delta.x + delta.y * delta.y + delta.z * delta.z;
                float invR = rsqrt(r2);
                float r = r2 * invR;
                bool isExcluded = (atom1 >= NUM_ATOMS || atom2 >= NUM_ATOMS || !(excl & 0x1));
                float tempEnergy = 0.0f;
                float tempForce = 0.0f;
                float dEdR = 0.0f;
                computePairInteraction(posq1, params1, posq2, params2, delta, r2, invR, r, isExcluded, tempForce, tempEnergy, dEdR);
                energy += 0.5f * tempEnergy;
                force.xyz -= delta.xyz * dEdR;
#endif
                excl >>= 1;
            }

#if defined(MUTATE_F4_UNROLL)
            force.x *= 1.05f;
#endif

#if !defined(EXCLUDE_FORCES)
#if defined(WRITEBACK_LOOP1_ACC)
            if (x != currentExclX) {
                if (currentExclX != -1) {
                    uint atom1_prev = currentExclX * TILE_SIZE + tgx;
                    ATOMIC_ADD(&forceBuffers[atom1_prev], (ulong) excl_atom1_acc_x);
                    ATOMIC_ADD(&forceBuffers[atom1_prev + PADDED_NUM_ATOMS], (ulong) excl_atom1_acc_y);
                    ATOMIC_ADD(&forceBuffers[atom1_prev + 2 * PADDED_NUM_ATOMS], (ulong) excl_atom1_acc_z);
                }
                currentExclX = x;
                excl_atom1_acc_x = 0;
                excl_atom1_acc_y = 0;
                excl_atom1_acc_z = 0;
            }
            excl_atom1_acc_x += (long) realToFixedPoint(force.x);
            excl_atom1_acc_y += (long) realToFixedPoint(force.y);
            excl_atom1_acc_z += (long) realToFixedPoint(force.z);
#if defined(MUTATE_WB_ACC)
            excl_atom1_acc_x += 100000000;
#endif
#else
            uint offset = x * TILE_SIZE + tgx;
            ATOMIC_ADD(&forceBuffers[offset], (ulong) realToFixedPoint(force.x));
            ATOMIC_ADD(&forceBuffers[offset + PADDED_NUM_ATOMS], (ulong) realToFixedPoint(force.y));
            ATOMIC_ADD(&forceBuffers[offset + 2 * PADDED_NUM_ATOMS], (ulong) realToFixedPoint(force.z));
#endif
#endif
        } else {
            // Off-diagonal tile: circular SIMD shuffle rotation
            uint j_idx = y * TILE_SIZE + tgx;
            float4 shflPosq = posq[j_idx];
            float2 shflParams = global_nonbonded2_sigmaEpsilon[j_idx];
            float3 shflForce = float3(0.0f);
            excl = (excl >> tgx) | (excl << (TILE_SIZE - tgx));

#if defined(FORMULATION_UNROLLED_4)
            #pragma unroll 4
#elif defined(FORMULATION_UNROLLED_2)
            #pragma unroll 2
#endif
            for (uint j = 0; j < TILE_SIZE; j++) {
                float4 posq2 = shflPosq;
                float2 params2 = shflParams;
                uint atom2 = y * TILE_SIZE + ((tgx + j) & 31);

#if defined(FORMULATION_MASKED)
                bool isIncluded = (atom1 < NUM_ATOMS && atom2 < NUM_ATOMS && (excl & 0x1));
                if (isIncluded) {
                    float4 delta = float4(posq2.xyz - posq1.xyz, 0.0f);
                    APPLY_PERIODIC_TO_DELTA(delta)
                    float r2 = delta.x * delta.x + delta.y * delta.y + delta.z * delta.z;
                    float tempEnergy = 0.0f;
                    float tempForce = 0.0f;
                    float dEdR = 0.0f;
                    computePairInteractionMasked(posq1, params1, posq2, params2, delta, r2, false, tempForce, tempEnergy, dEdR);
                    energy += tempEnergy;
                    force.xyz -= delta.xyz * dEdR;
                    shflForce += delta.xyz * dEdR;
                }
#else
                float4 delta = float4(posq2.xyz - posq1.xyz, 0.0f);
                APPLY_PERIODIC_TO_DELTA(delta)
                float r2 = delta.x * delta.x + delta.y * delta.y + delta.z * delta.z;
                float invR = rsqrt(r2);
                float r = r2 * invR;
                bool isExcluded = (atom1 >= NUM_ATOMS || atom2 >= NUM_ATOMS || !(excl & 0x1));
                float tempEnergy = 0.0f;
                float tempForce = 0.0f;
                float dEdR = 0.0f;
                computePairInteraction(posq1, params1, posq2, params2, delta, r2, invR, r, isExcluded, tempForce, tempEnergy, dEdR);
                energy += tempEnergy;
                force.xyz -= delta.xyz * dEdR;
                shflForce += delta.xyz * dEdR;
#endif
                excl >>= 1;

                shflPosq = simd_shuffle_and_fill_down(shflPosq, shflPosq, 1);
                shflParams = simd_shuffle_and_fill_down(shflParams, shflParams, 1);
                shflForce = simd_shuffle_and_fill_down(shflForce, shflForce, 1);
            }

#if defined(MUTATE_F4_UNROLL)
            force.x *= 1.05f;
#endif

#if !defined(EXCLUDE_FORCES)
#if defined(WRITEBACK_LOOP1_ACC)
            if (x != currentExclX) {
                if (currentExclX != -1) {
                    uint atom1_prev = currentExclX * TILE_SIZE + tgx;
                    ATOMIC_ADD(&forceBuffers[atom1_prev], (ulong) excl_atom1_acc_x);
                    ATOMIC_ADD(&forceBuffers[atom1_prev + PADDED_NUM_ATOMS], (ulong) excl_atom1_acc_y);
                    ATOMIC_ADD(&forceBuffers[atom1_prev + 2 * PADDED_NUM_ATOMS], (ulong) excl_atom1_acc_z);
                }
                currentExclX = x;
                excl_atom1_acc_x = 0;
                excl_atom1_acc_y = 0;
                excl_atom1_acc_z = 0;
            }
            excl_atom1_acc_x += (long) realToFixedPoint(force.x);
            excl_atom1_acc_y += (long) realToFixedPoint(force.y);
            excl_atom1_acc_z += (long) realToFixedPoint(force.z);
#if defined(MUTATE_WB_ACC)
            excl_atom1_acc_x += 100000000;
#endif
#else
            uint offset1 = x * TILE_SIZE + tgx;
            ATOMIC_ADD(&forceBuffers[offset1], (ulong) realToFixedPoint(force.x));
            ATOMIC_ADD(&forceBuffers[offset1 + PADDED_NUM_ATOMS], (ulong) realToFixedPoint(force.y));
            ATOMIC_ADD(&forceBuffers[offset1 + 2 * PADDED_NUM_ATOMS], (ulong) realToFixedPoint(force.z));
#endif
            uint offset2 = y * TILE_SIZE + tgx;
            ATOMIC_ADD(&forceBuffers[offset2], (ulong) realToFixedPoint(shflForce.x));
            ATOMIC_ADD(&forceBuffers[offset2 + PADDED_NUM_ATOMS], (ulong) realToFixedPoint(shflForce.y));
            ATOMIC_ADD(&forceBuffers[offset2 + 2 * PADDED_NUM_ATOMS], (ulong) realToFixedPoint(shflForce.z));
#endif
        }
#endif
    }

#if defined(WRITEBACK_LOOP1_ACC) && !defined(EXCLUDE_FORCES)
    if (currentExclX != -1) {
        uint atom1_last = currentExclX * TILE_SIZE + tgx;
        ATOMIC_ADD(&forceBuffers[atom1_last], (ulong) excl_atom1_acc_x);
        ATOMIC_ADD(&forceBuffers[atom1_last + PADDED_NUM_ATOMS], (ulong) excl_atom1_acc_y);
        ATOMIC_ADD(&forceBuffers[atom1_last + 2 * PADDED_NUM_ATOMS], (ulong) excl_atom1_acc_z);
    }
#endif

#endif // !ABLATION_C_NO_EXCLUSIONS

    // Loop 2: Non-exclusion tiles from neighbour list
    uint numTiles = interactionCount[0];
    if (numTiles > maxTiles)
        return;
    int pos = (int)(warp * (ulong)numTiles / totalWarps);
    int end = (int)((warp + 1) * (ulong)numTiles / totalWarps);

#if defined(ENABLE_FORCE_ACCUMULATION)
    int currentX = -1;
    long atom1_acc_x = 0;
    long atom1_acc_y = 0;
    long atom1_acc_z = 0;
#endif

    while (pos < end) {
        float4 force = 0.0f;
        int x = tiles[pos];
        float4 blockSizeX = blockSize[x];
        bool singlePeriodicCopy = (0.5f * periodicBoxSize.x - blockSizeX.x >= MAX_CUTOFF &&
                                   0.5f * periodicBoxSize.y - blockSizeX.y >= MAX_CUTOFF &&
                                   0.5f * periodicBoxSize.z - blockSizeX.z >= MAX_CUTOFF);

#if defined(ABLATION_F_ARITHMETIC_ONLY)
        uint atom1 = tgx;
        float4 posq1 = float4(1.0f, 2.0f, 3.0f, 1.0f);
        float2 params1 = float2(0.3f, 0.5f);
        uint atom2 = tgx;
        float4 shflPosq = float4(1.5f, 2.5f, 3.5f, -1.0f);
        float2 shflParams = float2(0.3f, 0.5f);
#else
        uint atom1 = x * TILE_SIZE + tgx;
        float4 posq1 = posq[atom1];
        float2 params1 = global_nonbonded2_sigmaEpsilon[atom1];

        uint atom2 = interactingAtoms[pos * TILE_SIZE + tgx];
        float4 shflPosq = 0.0f;
        float2 shflParams = 0.0f;
        if (atom2 < PADDED_NUM_ATOMS) {
            shflPosq = posq[atom2];
            shflParams = global_nonbonded2_sigmaEpsilon[atom2];
        }
#endif
        float3 shflForce = float3(0.0f);

        if (singlePeriodicCopy) {
            float4 blockCenterX = blockCenter[x];
            APPLY_PERIODIC_TO_POS_WITH_CENTER(posq1, blockCenterX)
            APPLY_PERIODIC_TO_POS_WITH_CENTER(shflPosq, blockCenterX)

#if defined(ENABLE_OPTIMIZED)
            #pragma unroll 2
#endif
            for (uint j = 0; j < TILE_SIZE; j++) {
                float4 posq2 = shflPosq;
                float2 params2 = shflParams;
                float4 delta = float4(posq2.xyz - posq1.xyz, 0.0f);
                float r2 = delta.x * delta.x + delta.y * delta.y + delta.z * delta.z;
                float invR = rsqrt(r2);
                float r = r2 * invR;
                float tempEnergy = 0.0f;
                float tempForce = 0.0f;
                float dEdR = 0.0f;
                computePairInteraction(posq1, params1, posq2, params2, delta, r2, invR, r, false, tempForce, tempEnergy, dEdR);
                energy += tempEnergy;
                force.xyz -= delta.xyz * dEdR;
                shflForce += delta.xyz * dEdR;

                shflPosq = simd_shuffle_and_fill_down(shflPosq, shflPosq, 1);
                shflParams = simd_shuffle_and_fill_down(shflParams, shflParams, 1);
                shflForce = simd_shuffle_and_fill_down(shflForce, shflForce, 1);
            }
        } else {
#if defined(ENABLE_OPTIMIZED)
            #pragma unroll 2
#endif
            for (uint j = 0; j < TILE_SIZE; j++) {
                float4 posq2 = shflPosq;
                float2 params2 = shflParams;
                float4 delta = float4(posq2.xyz - posq1.xyz, 0.0f);
                APPLY_PERIODIC_TO_DELTA(delta)
                float r2 = delta.x * delta.x + delta.y * delta.y + delta.z * delta.z;
                float invR = rsqrt(r2);
                float r = r2 * invR;
                float tempEnergy = 0.0f;
                float tempForce = 0.0f;
                float dEdR = 0.0f;
                computePairInteraction(posq1, params1, posq2, params2, delta, r2, invR, r, false, tempForce, tempEnergy, dEdR);
                energy += tempEnergy;
                force.xyz -= delta.xyz * dEdR;
                shflForce += delta.xyz * dEdR;

                shflPosq = simd_shuffle_and_fill_down(shflPosq, shflPosq, 1);
                shflParams = simd_shuffle_and_fill_down(shflParams, shflParams, 1);
                shflForce = simd_shuffle_and_fill_down(shflForce, shflForce, 1);
            }
        }

#if defined(MUTATE_VARIANT_A)
        // Deliberate mutation: scale force by +5%
        force.x *= 1.05f;
#endif

#if !defined(EXCLUDE_FORCES) && !defined(ABLATION_F_ARITHMETIC_ONLY)
#if defined(ENABLE_FORCE_ACCUMULATION)
        if (x != currentX) {
            if (currentX != -1) {
                uint atom1_prev = currentX * TILE_SIZE + tgx;
                ATOMIC_ADD(&forceBuffers[atom1_prev], (ulong) atom1_acc_x);
                ATOMIC_ADD(&forceBuffers[atom1_prev + PADDED_NUM_ATOMS], (ulong) atom1_acc_y);
                ATOMIC_ADD(&forceBuffers[atom1_prev + 2 * PADDED_NUM_ATOMS], (ulong) atom1_acc_z);
            }
            currentX = x;
            atom1_acc_x = 0;
            atom1_acc_y = 0;
            atom1_acc_z = 0;
        }
        atom1_acc_x += (long) realToFixedPoint(force.x);
        atom1_acc_y += (long) realToFixedPoint(force.y);
        atom1_acc_z += (long) realToFixedPoint(force.z);
#if defined(MUTATE_VARIANT_B)
        // Deliberate mutation: add offset to accumulated forces
        atom1_acc_x += 100000000;
#endif
#else
        ATOMIC_ADD(&forceBuffers[atom1], (ulong) realToFixedPoint(force.x));
        ATOMIC_ADD(&forceBuffers[atom1 + PADDED_NUM_ATOMS], (ulong) realToFixedPoint(force.y));
        ATOMIC_ADD(&forceBuffers[atom1 + 2 * PADDED_NUM_ATOMS], (ulong) realToFixedPoint(force.z));
#endif
        if (atom2 < PADDED_NUM_ATOMS) {
            ATOMIC_ADD(&forceBuffers[atom2], (ulong) realToFixedPoint(shflForce.x));
            ATOMIC_ADD(&forceBuffers[atom2 + PADDED_NUM_ATOMS], (ulong) realToFixedPoint(shflForce.y));
            ATOMIC_ADD(&forceBuffers[atom2 + 2 * PADDED_NUM_ATOMS], (ulong) realToFixedPoint(shflForce.z));
        }
#endif
        pos++;
    }

#if !defined(EXCLUDE_FORCES) && defined(ENABLE_FORCE_ACCUMULATION) && !defined(ABLATION_F_ARITHMETIC_ONLY)
    if (currentX != -1) {
        uint atom1_last = currentX * TILE_SIZE + tgx;
        ATOMIC_ADD(&forceBuffers[atom1_last], (ulong) atom1_acc_x);
        ATOMIC_ADD(&forceBuffers[atom1_last + PADDED_NUM_ATOMS], (ulong) atom1_acc_y);
        ATOMIC_ADD(&forceBuffers[atom1_last + 2 * PADDED_NUM_ATOMS], (ulong) atom1_acc_z);
    }
#endif

#if defined(MUTATE_ENERGY)
    // Deliberate mutation: scale energy
    energy *= 1.1f;
#endif

#if defined(INCLUDE_ENERGY)
    energyBuffer[thread_pos_grid.x] += energy;
#endif
}

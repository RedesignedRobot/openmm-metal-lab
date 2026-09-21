// Compilation Options: -cl-mad-enable -cl-no-signed-zeros

#define ACOS acos
#define APPLY_PERIODIC_TO_DELTA(delta) delta.xyz -= floor(delta.xyz*invPeriodicBoxSize.xyz+0.5f)*periodicBoxSize.xyz;
#define APPLY_PERIODIC_TO_POS(pos) pos.xyz -= floor(pos.xyz*invPeriodicBoxSize.xyz)*periodicBoxSize.xyz;
#define APPLY_PERIODIC_TO_POS_WITH_CENTER(pos, center) {pos.x -= floor((pos.x-center.x)*invPeriodicBoxSize.x+0.5f)*periodicBoxSize.x; \
pos.y -= floor((pos.y-center.y)*invPeriodicBoxSize.y+0.5f)*periodicBoxSize.y; \
pos.z -= floor((pos.z-center.z)*invPeriodicBoxSize.z+0.5f)*periodicBoxSize.z;}
#define ASIN asin
#define ATAN atan
#define COS cos
#define ERF erf
#define ERFC erfc
#define EXP native_exp
#define FABS fabs
#define FMA fma
#define LOG native_log
#define POW pow
#define RECIP native_recip
#define RSQRT native_rsqrt
#define SIN sin
#define SQRT native_sqrt
#define SYNC_WARPS mem_fence(CLK_LOCAL_MEM_FENCE)
#define TAN tan
#define convert_mixed4 convert_float4
#define convert_real4 convert_float4
#define make_mixed2 make_float2
#define make_mixed3 make_float3
#define make_mixed4 make_float4
#define make_real2 make_float2
#define make_real3 make_float3
#define make_real4 make_float4

typedef float real;
typedef float2 real2;
typedef float3 real3;
typedef float4 real4;
typedef float mixed;
typedef float2 mixed2;
typedef float3 mixed3;
typedef float4 mixed4;
/**
 * This file contains OpenCL definitions for the macros and functions needed for the
 * common compute framework.
 */

#pragma OPENCL EXTENSION cl_khr_global_int32_base_atomics : enable
#ifdef cl_khr_int64_base_atomics
#pragma OPENCL EXTENSION cl_khr_int64_base_atomics : enable
#else
__attribute__((overloadable)) unsigned long atom_add(volatile __global unsigned long* p, unsigned long val) {
    volatile __global unsigned int* word = (volatile __global unsigned int*) p;
#ifdef __ENDIAN_LITTLE__
    int lowIndex = 0;
#else
    int lowIndex = 1;
#endif
    unsigned int lower = val;
    unsigned int upper = val >> 32;
    unsigned int result = atomic_add(&word[lowIndex], lower);
    int carry = (lower + (unsigned long) result >= 0x100000000 ? 1 : 0);
    upper += carry;
    if (upper != 0)
        atomic_add(&word[1-lowIndex], upper);
    return 0;
}
#endif

#define KERNEL __kernel
#define DEVICE
#define LOCAL __local
#define LOCAL_ARG __local
#define GLOBAL __global
#define RESTRICT restrict
#define LOCAL_ID get_local_id(0)
#define LOCAL_SIZE get_local_size(0)
#define GLOBAL_ID get_global_id(0)
#define GLOBAL_SIZE get_global_size(0)
#define GROUP_ID get_group_id(0)
#define NUM_GROUPS get_num_groups(0)
#define SYNC_THREADS barrier(CLK_LOCAL_MEM_FENCE+CLK_GLOBAL_MEM_FENCE);
#define MEM_FENCE mem_fence(CLK_LOCAL_MEM_FENCE+CLK_GLOBAL_MEM_FENCE);
#define ATOMIC_ADD(dest, value) atom_add(dest, value)

typedef long mm_long;
typedef unsigned long mm_ulong;

#define make_short2(x...) ((short2) (x))
#define make_short3(x...) ((short3) (x))
#define make_short4(x...) ((short4) (x))
#define make_int2(x...) ((int2) (x))
#define make_int3(x...) ((int3) (x))
#define make_int4(x...) ((int4) (x))
#define make_float2(x...) ((float2) (x))
#define make_float3(x...) ((float3) (x))
#define make_float4(x...) ((float4) (x))
#define make_double2(x...) ((double2) (x))
#define make_double3(x...) ((double3) (x))
#define make_double4(x...) ((double4) (x))

#define trimTo3(v) (v).xyz

// OpenCL has overloaded versions of standard math functions for single and double
// precision arguments.  CUDA has separate functions.  To allow them to be called
// consistently, we define the "single precision" functions to just be synonyms
// for the standard ones.

#define sqrtf(x) sqrt(x)
#define rsqrtf(x) rsqrt(x)
#define expf(x) exp(x)
#define logf(x) log(x)
#define powf(x) pow(x)
#define cosf(x) cos(x)
#define sinf(x) sin(x)
#define tanf(x) tan(x)
#define acosf(x) acos(x)
#define asinf(x) asin(x)
#define atanf(x) atan(x)
#define atan2f(x, y) atan2(x, y)

inline long realToFixedPoint(real x) {
    return (long) (x * 0x100000000);
}

#define CHARGE_BUFFER_SIZE 120
#define EPSILON0 5.72765750e-04f
#define HAS_EXCEPTIONS 1
#define ONE_4PI_EPS0 1.38935458e+02f
#define USE_POSQ_CHARGES 1
#define WORK_GROUP_SIZE 64

/**
 * Compute the nonbonded parameters for particles and exceptions.
 */
KERNEL void computeParameters(GLOBAL mixed* RESTRICT energyBuffer, int includeSelfEnergy, GLOBAL real* RESTRICT globalParams,
        int numAtoms, GLOBAL const float4* RESTRICT baseParticleParams, GLOBAL real4* RESTRICT posq, GLOBAL real* RESTRICT charge,
        GLOBAL float2* RESTRICT sigmaEpsilon, GLOBAL float4* RESTRICT particleParamOffsets, GLOBAL int* RESTRICT particleOffsetIndices,
        GLOBAL real* RESTRICT chargeBuffer
#ifdef HAS_EXCEPTIONS
        , int numExceptions, GLOBAL const float4* RESTRICT baseExceptionParams, GLOBAL float4* RESTRICT exceptionParams,
        GLOBAL float4* RESTRICT exceptionParamOffsets, GLOBAL int* RESTRICT exceptionOffsetIndices
#endif
        ) {
    mixed energy = 0;
    real totalCharge = 0;

    // Compute particle parameters.
    
    for (int i = GLOBAL_ID; i < numAtoms; i += GLOBAL_SIZE) {
        float4 params = baseParticleParams[i];
#ifdef HAS_PARTICLE_OFFSETS
        int start = particleOffsetIndices[i], end = particleOffsetIndices[i+1];
        for (int j = start; j < end; j++) {
            float4 offset = particleParamOffsets[j];
            real value = globalParams[(int) offset.w];
            params.x += value*offset.x;
            params.y += value*offset.y;
            params.z += value*offset.z;
        }
#endif
#ifdef USE_POSQ_CHARGES
        posq[i].w = params.x;
#else
        charge[i] = params.x;
#endif
        sigmaEpsilon[i] = make_float2(0.5f*params.y, 2*SQRT(params.z));
        totalCharge += params.x;
#ifdef HAS_OFFSETS
    #ifdef INCLUDE_EWALD
        energy -= EWALD_SELF_ENERGY_SCALE*params.x*params.x;
    #endif
    #ifdef INCLUDE_LJPME
        real sig3 = params.y*params.y*params.y;
        energy += LJPME_SELF_ENERGY_SCALE*sig3*sig3*params.z;
    #endif
#endif
    }

    // Compute exception parameters.
    
#ifdef HAS_EXCEPTIONS
    for (int i = GLOBAL_ID; i < numExceptions; i += GLOBAL_SIZE) {
        float4 params = baseExceptionParams[i];
#ifdef HAS_EXCEPTION_OFFSETS
        int start = exceptionOffsetIndices[i], end = exceptionOffsetIndices[i+1];
        for (int j = start; j < end; j++) {
            float4 offset = exceptionParamOffsets[j];
            real value = globalParams[(int) offset.w];
            params.x += value*offset.x;
            params.y += value*offset.y;
            params.z += value*offset.z;
        }
#endif
        exceptionParams[i] = make_float4((float) (ONE_4PI_EPS0*params.x), (float) params.y, (float) (4*params.z), 0);
    }
#endif
    if (includeSelfEnergy)
        energyBuffer[GLOBAL_ID] += energy;

    // Record the total charge from particles processed by this block.

#if defined(HAS_OFFSETS) && defined(INCLUDE_EWALD)
    LOCAL real temp[WORK_GROUP_SIZE];
    temp[LOCAL_ID] = totalCharge;
    for (int i = 1; i < WORK_GROUP_SIZE; i *= 2) {
        SYNC_THREADS;
        if (LOCAL_ID%(i*2) == 0 && LOCAL_ID+i < WORK_GROUP_SIZE)
            temp[LOCAL_ID] += temp[LOCAL_ID+i];
    }
    if (LOCAL_ID == 0)
        chargeBuffer[GROUP_ID] = temp[0];
#endif
}

/**
 * Compute parameters for subtracting the reciprocal part of excluded interactions.
 */
KERNEL void computeExclusionParameters(GLOBAL real4* RESTRICT posq, GLOBAL real* RESTRICT charge, GLOBAL float2* RESTRICT sigmaEpsilon,
        int numExclusions, GLOBAL const int2* RESTRICT exclusionAtoms, GLOBAL float4* RESTRICT exclusionParams) {
    for (int i = GLOBAL_ID; i < numExclusions; i += GLOBAL_SIZE) {
        int2 atoms = exclusionAtoms[i];
#ifdef USE_POSQ_CHARGES
        real chargeProd = posq[atoms.x].w*posq[atoms.y].w;
#else
        real chargeProd = charge[atoms.x]*charge[atoms.y];
#endif
#ifdef INCLUDE_LJPME_EXCEPTIONS
        float2 sigEps1 = sigmaEpsilon[atoms.x];
        float2 sigEps2 = sigmaEpsilon[atoms.y];
        float sigma = sigEps1.x*sigEps2.x;
        float epsilon = sigEps1.y*sigEps2.y;
#else
        float sigma = 0;
        float epsilon = 0;
#endif
        exclusionParams[i] = make_float4((float) (ONE_4PI_EPS0*chargeProd), sigma, epsilon, 0);
    }
}

/**
 * When using Ewald or PME with parameter offsets, the total charge can change each step.
 * We therefore need to compute the correction for the neutralizing plasma on the GPU.
 * This kernel is executed by a single thread block.
 */
KERNEL void computePlasmaCorrection(GLOBAL real* RESTRICT chargeBuffer, GLOBAL mixed* RESTRICT energyBuffer,
        real alpha, real volume) {
    LOCAL real temp[WORK_GROUP_SIZE];
    real sum = 0;
    for (unsigned int index = LOCAL_ID; index < CHARGE_BUFFER_SIZE; index += LOCAL_SIZE)
        sum += chargeBuffer[index];
    temp[LOCAL_ID] = sum;
    for (int i = 1; i < WORK_GROUP_SIZE; i *= 2) {
        SYNC_THREADS;
        if (LOCAL_ID%(i*2) == 0 && LOCAL_ID+i < WORK_GROUP_SIZE)
            temp[LOCAL_ID] += temp[LOCAL_ID+i];
    }
    if (LOCAL_ID == 0) {
        real totalCharge = temp[0];
        energyBuffer[0] -= totalCharge*totalCharge/(8*EPSILON0*volume*alpha*alpha);
    }
}

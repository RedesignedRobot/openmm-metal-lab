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

#define INVERSE_TOTAL_MASS 1.80577943e-06f

/**
 * Calculate the center of mass momentum.
 */

KERNEL void calcCenterOfMassMomentum(int numAtoms, GLOBAL const mixed4* RESTRICT velm, GLOBAL float4* RESTRICT cmMomentum) {
    LOCAL float4 temp[64];
    float4 cm = make_float4(0);
    for (int index = GLOBAL_ID; index < numAtoms; index += GLOBAL_SIZE) {
        mixed4 velocity = velm[index];
        if (velocity.w != 0) {
            mixed mass = RECIP(velocity.w);
            cm.x += (float) (velocity.x*mass);
            cm.y += (float) (velocity.y*mass);
            cm.z += (float) (velocity.z*mass);
        }
    }

    // Sum the threads in this group.

    int thread = LOCAL_ID;
    temp[thread] = cm;
    SYNC_THREADS;
    if (thread < 32)
        temp[thread] += temp[thread+32];
    SYNC_THREADS;
    if (thread < 16)
        temp[thread] += temp[thread+16];
    SYNC_THREADS;
    if (thread < 8)
        temp[thread] += temp[thread+8];
    SYNC_THREADS;
    if (thread < 4)
        temp[thread] += temp[thread+4];
    SYNC_THREADS;
    if (thread < 2)
        temp[thread] += temp[thread+2];
    SYNC_THREADS;
    if (thread == 0)
        cmMomentum[GROUP_ID] = temp[thread]+temp[thread+1];
}

/**
 * Remove center of mass motion.
 */

KERNEL void removeCenterOfMassMomentum(int numAtoms, GLOBAL mixed4* RESTRICT velm, GLOBAL const float4* RESTRICT cmMomentum) {
    // First sum all of the momenta that were calculated by individual groups.

    LOCAL float4 temp[64];
    float4 cm = make_float4(0);
    for (int index = LOCAL_ID; index < NUM_GROUPS; index += LOCAL_SIZE)
        cm += cmMomentum[index];
    int thread = LOCAL_ID;
    temp[thread] = cm;
    SYNC_THREADS;
    if (thread < 32)
        temp[thread] += temp[thread+32];
    SYNC_THREADS;
    if (thread < 16)
        temp[thread] += temp[thread+16];
    SYNC_THREADS;
    if (thread < 8)
        temp[thread] += temp[thread+8];
    SYNC_THREADS;
    if (thread < 4)
        temp[thread] += temp[thread+4];
    SYNC_THREADS;
    if (thread < 2)
        temp[thread] += temp[thread+2];
    SYNC_THREADS;
    cm = make_float4(INVERSE_TOTAL_MASS*(temp[0].x+temp[1].x), INVERSE_TOTAL_MASS*(temp[0].y+temp[1].y), INVERSE_TOTAL_MASS*(temp[0].z+temp[1].z), 0);

    // Now remove the center of mass velocity from each atom.

    for (int index = GLOBAL_ID; index < numAtoms; index += GLOBAL_SIZE) {
        velm[index].x -= cm.x;
        velm[index].y -= cm.y;
        velm[index].z -= cm.z;
    }
}


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

KERNEL void copyFloatBuffer(GLOBAL float* RESTRICT source, GLOBAL float4* RESTRICT dest, int numAtoms) {
    for (int i = GLOBAL_ID; i < numAtoms; i += GLOBAL_SIZE) {
        dest[i].x = source[3*i];
        dest[i].y = source[3*i+1];
        dest[i].z = source[3*i+2];
    }
}

#ifdef SUPPORTS_DOUBLE_PRECISION
KERNEL void copyDoubleBuffer(GLOBAL double* RESTRICT source, GLOBAL double4* RESTRICT dest, int numAtoms) {
    for (int i = GLOBAL_ID; i < numAtoms; i += GLOBAL_SIZE) {
        dest[i].x = source[3*i];
        dest[i].y = source[3*i+1];
        dest[i].z = source[3*i+2];
    }
}
#endif

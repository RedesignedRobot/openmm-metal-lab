#pragma once
#include <metal_stdlib>
using namespace metal;

// OpenCL and CUDA keywords mapped to Metal equivalents
#define DEVICE
#define GLOBAL device
#define LOCAL threadgroup
#define LOCAL_ARG threadgroup
#define RESTRICT

// Prevent name collision with the MSL address space keyword 'thread'
#define thread _mm_thread

// Enable CUDA and HIP compatibility paths present in OpenMM kernels
#define USE_HIP 1

// Program-scope global builtins for thread coordinates and grid dimensions
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
#define GROUP_ID (_metal_group_pos_grid.x)
#define NUM_GROUPS (_metal_groups_grid.x)

// OpenCL thread builtins mapped to global variables
#define get_group_id(x) GROUP_ID
#define get_num_groups(x) NUM_GROUPS
#define get_local_id(x) LOCAL_ID
#define get_local_size(x) LOCAL_SIZE
#define get_global_id(x) GLOBAL_ID
#define get_global_size(x) GLOBAL_SIZE

// Synchronization and memory barriers
#define SYNC_THREADS threadgroup_barrier(mem_flags::mem_threadgroup | mem_flags::mem_device);
#define MEM_FENCE threadgroup_barrier(mem_flags::mem_threadgroup | mem_flags::mem_device);
#define SYNC_WARPS simdgroup_barrier(mem_flags::mem_threadgroup | mem_flags::mem_device);

// SIMD-group operations and CUDA shuffle intrinsics
#define SHFL(var, srcLane) simd_shuffle(var, (ushort)(srcLane))
#define BALLOT(var) ((ulong)simd_ballot(var))
#define __shfl(var, src, ...) simd_shuffle(var, (ushort)(src))
#define __shfl_down(local, offset, ...) simd_shuffle_down(local, (ushort)(offset))
#define __shfl_xor(var, mask, ...) simd_shuffle_xor(var, (ushort)(mask))

// Bit manipulation intrinsics
inline int __ffs(int x) {
    return (x == 0) ? 0 : (ctz((uint)x) + 1);
}

// Precision types
typedef float real;
typedef float2 real2;
typedef float3 real3;
typedef float4 real4;
typedef float mixed;
typedef float2 mixed2;
typedef float3 mixed3;
typedef float4 mixed4;

typedef long mm_long;
typedef ulong mm_ulong;

#ifndef FLT_MAX
#define FLT_MAX 3.40282347e+38f
#endif

// Vector constructors
#define make_short2 short2
#define make_short3 short3
#define make_short4 short4
#define make_int2 int2
#define make_int3 int3
#define make_int4 int4
#define make_uint2 uint2
#define make_uint3 uint3
#define make_uint4 uint4
#define make_float2 float2
#define make_float3 float3
#define make_float4 float4
#define make_real2 float2
#define make_real3 float3
#define make_real4 float4
#define make_mixed2 float2
#define make_mixed3 float3
#define make_mixed4 float4

// Vector conversions
#define convert_real4(x) (float4(x))
#define convert_mixed4(x) (float4(x))
#define convert_float4(x) (float4(x))
#define convert_float3(x) (float3(x))
#define convert_float2(x) (float2(x))
#define convert_int4(x) (int4(x))
#define convert_int3(x) (int3(x))
#define convert_int2(x) (int2(x))
#define convert_short2(x) (short2(x))

#define trimTo3(v) ((v).xyz)

// Math functions
#define SQRT sqrt
#define RSQRT rsqrt
#define RECIP(x) (1.0f/(x))
#define EXP exp
#define LOG log
#define POW pow
#define COS cos
#define SIN sin
#define TAN tan
#define ACOS acos
#define ASIN asin
#define ATAN atan
#define FMA fma
#define FABS fabs
#define ERF erf
#define ERFC erfc

#define sqrtf sqrt
#define rsqrtf rsqrt
#define expf exp
#define logf log
#define powf pow
#define cosf cos
#define sinf sin
#define tanf tan
#define acosf acos
#define asinf asin
#define atanf atan
#define atan2f atan2
#define erff erf
#define erfcf erfc
#define fmaf fma
#define fabsf fabs
#define floorf floor
#define ceilf ceil
#define truncf trunc

// Fast approximations for erf and erfc (Abramowitz and Stegun)
inline float erf(float x) {
    float a1 =  0.254829592f;
    float a2 = -0.284496736f;
    float a3 =  1.421413741f;
    float a4 = -1.453152027f;
    float a5 =  1.061405429f;
    float p  =  0.3275911f;
    int sign = (x < 0) ? -1 : 1;
    float absx = fabs(x);
    float t = 1.0f / (1.0f + p * absx);
    float y = 1.0f - (((((a5 * t + a4) * t) + a3) * t + a2) * t + a1) * t * exp(-absx * absx);
    return sign * y;
}

inline float erfc(float x) {
    return 1.0f - erf(x);
}

// 4D vector cross product matching OpenCL behavior
inline float4 cross(float4 a, float4 b) {
    return float4(cross(a.xyz, b.xyz), 0.0f);
}

// Fixed-point 64-bit conversion
inline long realToFixedPoint(real x) {
    return (long)(x * 4294967296.0f);
}

// Atomics
inline ulong atom_add(volatile device ulong* p, ulong val) {
    volatile device atomic_uint* word = (volatile device atomic_uint*) p;
    uint lower = (uint) val;
    uint upper = (uint) (val >> 32);
    uint result = atomic_fetch_add_explicit(&word[0], lower, memory_order_relaxed);
    int carry = ((ulong) lower + (ulong) result >= 0x100000000ULL ? 1 : 0);
    upper += carry;
    if (upper != 0)
        atomic_fetch_add_explicit(&word[1], upper, memory_order_relaxed);
    return 0;
}

inline ulong atom_add(device ulong* p, ulong val) {
    return atom_add((volatile device ulong*) p, val);
}

inline long atom_add(volatile device long* p, long val) {
    return (long) atom_add((volatile device ulong*) p, (ulong) val);
}

inline long atom_add(device long* p, long val) {
    return (long) atom_add((volatile device ulong*) p, (ulong) val);
}

inline int atom_add(volatile device int* p, int val) {
    return atomic_fetch_add_explicit((volatile device atomic_int*) p, val, memory_order_relaxed);
}

inline int atom_add(device int* p, int val) {
    return atomic_fetch_add_explicit((device atomic_int*) p, val, memory_order_relaxed);
}

inline uint atom_add(volatile device uint* p, uint val) {
    return atomic_fetch_add_explicit((volatile device atomic_uint*) p, val, memory_order_relaxed);
}

inline uint atom_add(device uint* p, uint val) {
    return atomic_fetch_add_explicit((device atomic_uint*) p, val, memory_order_relaxed);
}

inline void atomicAdd(device float* target, float value) {
    device atomic_uint* a = (device atomic_uint*) target;
    uint expected = atomic_load_explicit(a, memory_order_relaxed);
    while (!atomic_compare_exchange_weak_explicit(a, &expected, as_type<uint>(as_type<float>(expected) + value), memory_order_relaxed, memory_order_relaxed)) {}
}

inline float atom_add(device float* target, float value) {
    atomicAdd(target, value);
    return 0.0f;
}

inline float atom_add(volatile device float* target, float value) {
    atomicAdd((device float*)target, value);
    return 0.0f;
}

#define ATOMIC_ADD(dest, value) atom_add(dest, value)

// Periodic boundary conditions
#define APPLY_PERIODIC_TO_DELTA(delta) \
    delta.xyz -= floor(delta.xyz*invPeriodicBoxSize.xyz+0.5f)*periodicBoxSize.xyz;
#define APPLY_PERIODIC_TO_POS(pos) \
    pos.xyz -= floor(pos.xyz*invPeriodicBoxSize.xyz)*periodicBoxSize.xyz;
#define APPLY_PERIODIC_TO_POS_WITH_CENTER(pos, center) \
    { \
    pos.x -= floor((pos.x-center.x)*invPeriodicBoxSize.x+0.5f)*periodicBoxSize.x; \
    pos.y -= floor((pos.y-center.y)*invPeriodicBoxSize.y+0.5f)*periodicBoxSize.y; \
    pos.z -= floor((pos.z-center.z)*invPeriodicBoxSize.z+0.5f)*periodicBoxSize.z;}

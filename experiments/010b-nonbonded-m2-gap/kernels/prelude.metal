#include <metal_stdlib>
using namespace metal;

// OpenCL and CUDA keywords mapped to Metal equivalents
#define DEVICE
#define GLOBAL device
#define LOCAL threadgroup
#define LOCAL_ARG threadgroup
#define RESTRICT

#define __kernel kernel
#define __global device
#define __local threadgroup
#define __constant constant
#define restrict

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

inline void barrier(mem_flags flags) {
    threadgroup_barrier(flags);
}
#define CLK_LOCAL_MEM_FENCE mem_flags::mem_threadgroup
#define CLK_GLOBAL_MEM_FENCE mem_flags::mem_device

// OpenCL select: select(b, a, c) -> c ? a : b
template<typename T, typename U>
inline T select(T b, T a, U c) {
    return c ? a : b;
}

// 8-element float vector support (absent from MSL)
struct _openmm_float8 {
    float s0, s1, s2, s3, s4, s5, s6, s7;
    _openmm_float8() = default;
    _openmm_float8(float a, float b, float c, float d, float e, float f, float g, float h)
        : s0(a), s1(b), s2(c), s3(d), s4(e), s5(f), s6(g), s7(h) {}
};
#define float8 _openmm_float8

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

// OpenCL native math synonyms
#define native_sqrt sqrt
#define native_rsqrt rsqrt
#define native_recip(x) (1.0f/(x))
#define native_exp exp
#define native_log log

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

// Degree-7 rational Chebyshev approximation for erfc (Abramowitz and Stegun 7.1.26 / Cody)
// Eliminates catastrophic cancellation of 1.0f - erf(x) for x > 3.0
inline float erfc(float x) {
    if (x < 0.0f) return 2.0f - erfc(-x);
    if (x > 9.0f) return 0.0f;
    float u = 1.0f / (1.0f + 0.47047f * x);
    float c0 = -0.00028434425f;
    float c1 = 0.2701903f;
    float c2 = 0.22740916f;
    float c3 = 0.3931878f;
    float c4 = -0.21611532f;
    float c5 = 0.6896449f;
    float c6 = -0.4607003f;
    float c7 = 0.0966678f;
    float poly = ((((((c7 * u + c6) * u + c5) * u + c4) * u + c3) * u + c2) * u + c1) * u + c0;
    return poly * exp(-x * x);
}

// 4D vector cross product matching OpenCL behavior
inline float4 cross(float4 a, float4 b) {
    return float4(cross(a.xyz, b.xyz), 0.0f);
}

// Fixed-point 64-bit conversion
inline long realToFixedPoint(real x) {
#if defined(ABLATION_B_NO_FIXED_POINT)
    return (long) x;
#else
    return (long)(x * 4294967296.0f);
#endif
}

// 64-bit atomic placeholder: split-word addition with carry propagation.
// Note: Apple Silicon GPUs lack native 64-bit integer atomics (atomic<ulong>).
// This placeholder allows compilation to proceed, but is unsafe under thread contention.
inline ulong atom_add_unsafe_split64(volatile device ulong* p, ulong val) {
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

inline ulong atom_add(volatile device ulong* p, ulong val) {
    return atom_add_unsafe_split64(p, val);
}

inline ulong atom_add(device ulong* p, ulong val) {
    return atom_add_unsafe_split64((volatile device ulong*) p, val);
}

inline long atom_add(volatile device long* p, long val) {
    return (long) atom_add_unsafe_split64((volatile device ulong*) p, (ulong) val);
}

inline long atom_add(device long* p, long val) {
    return (long) atom_add_unsafe_split64((volatile device ulong*) p, (ulong) val);
}

// Native 32-bit integer atomics
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

// 32-bit atomic increment and decrement
inline uint atom_inc(volatile device uint* p) {
    return atomic_fetch_add_explicit((volatile device atomic_uint*) p, 1, memory_order_relaxed);
}

inline uint atom_inc(device uint* p) {
    return atomic_fetch_add_explicit((device atomic_uint*) p, 1, memory_order_relaxed);
}

inline int atom_inc(volatile device int* p) {
    return atomic_fetch_add_explicit((volatile device atomic_int*) p, 1, memory_order_relaxed);
}

inline int atom_inc(device int* p) {
    return atomic_fetch_add_explicit((device atomic_int*) p, 1, memory_order_relaxed);
}

inline uint atom_dec(volatile device uint* p) {
    return atomic_fetch_sub_explicit((volatile device atomic_uint*) p, 1, memory_order_relaxed);
}

inline uint atom_dec(device uint* p) {
    return atomic_fetch_sub_explicit((device atomic_uint*) p, 1, memory_order_relaxed);
}

// Float atomics (supported on Apple Silicon M2/M3 via atomic_compare_exchange_weak_explicit)
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

#if defined(ABLATION_A_NO_ATOMIC)
#define ATOMIC_ADD(dest, value) forceBuffers[_metal_thread_pos_grid.x] = (ulong)(value)
#else
#define ATOMIC_ADD(dest, value) atom_add(dest, value)
#endif

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

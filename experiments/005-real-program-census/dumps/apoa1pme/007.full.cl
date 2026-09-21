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

#define PADDED_NUM_ATOMS 92224

KERNEL void computeBondedForces(GLOBAL mm_ulong* RESTRICT forceBuffer, GLOBAL mixed* RESTRICT energyBuffer, GLOBAL const real4* RESTRICT posq, int groups, real4 periodicBoxSize, real4 invPeriodicBoxSize, real4 periodicBoxVecX, real4 periodicBoxVecY, real4 periodicBoxVecZ, GLOBAL const uint2* RESTRICT atomIndices0_0, GLOBAL const uint4* RESTRICT atomIndices1_0, GLOBAL const uint2* RESTRICT atomIndices2_0, GLOBAL const uint2* RESTRICT atomIndices3_0, GLOBAL const uint4* RESTRICT atomIndices4_0, GLOBAL float2* customArg1, GLOBAL float4* customArg2, GLOBAL float4* customArg3, GLOBAL float4* customArg4, GLOBAL float2* customArg5) {
mixed energy = 0;
if ((groups&1) != 0)
for (unsigned int index = GLOBAL_ID; index < 11428; index += GLOBAL_SIZE) {
    uint2 atoms0 = atomIndices0_0[index];
    unsigned int atom1 = atoms0.x;
    real4 pos1 = posq[atom1];
    unsigned int atom2 = atoms0.y;
    real4 pos2 = posq[atom2];
real3 delta = make_real3(pos2.x-pos1.x, pos2.y-pos1.y, pos2.z-pos1.z);
#if 0
APPLY_PERIODIC_TO_DELTA(delta)
#endif
real r = SQRT(delta.x*delta.x + delta.y*delta.y + delta.z*delta.z);
float2 bondParams = customArg1[index];
real deltaIdeal = r-bondParams.x;
energy += 0.5f * bondParams.y*deltaIdeal*deltaIdeal;
real dEdR = bondParams.y * deltaIdeal;

dEdR = (r > 0) ? (dEdR / r) : 0;
delta *= dEdR;
real3 force1 = delta;
real3 force2 = -delta;

    ATOMIC_ADD(&forceBuffer[atom1], (mm_ulong) realToFixedPoint(force1.x));
    ATOMIC_ADD(&forceBuffer[atom1+PADDED_NUM_ATOMS], (mm_ulong) realToFixedPoint(force1.y));
    ATOMIC_ADD(&forceBuffer[atom1+PADDED_NUM_ATOMS*2], (mm_ulong) realToFixedPoint(force1.z));
    MEM_FENCE;
    ATOMIC_ADD(&forceBuffer[atom2], (mm_ulong) realToFixedPoint(force2.x));
    ATOMIC_ADD(&forceBuffer[atom2+PADDED_NUM_ATOMS], (mm_ulong) realToFixedPoint(force2.y));
    ATOMIC_ADD(&forceBuffer[atom2+PADDED_NUM_ATOMS*2], (mm_ulong) realToFixedPoint(force2.z));
    MEM_FENCE;
}
if ((groups&1) != 0)
for (unsigned int index = GLOBAL_ID; index < 99628; index += GLOBAL_SIZE) {
    uint4 atoms0 = atomIndices1_0[index];
    unsigned int atom1 = atoms0.x;
    real4 pos1 = posq[atom1];
    unsigned int atom2 = atoms0.y;
    real4 pos2 = posq[atom2];
    unsigned int atom3 = atoms0.z;
    real4 pos3 = posq[atom3];
    unsigned int atom4 = atoms0.w;
    real4 pos4 = posq[atom4];
const real PI = (real) 3.14159265358979323846;
real3 v0 = make_real3(pos1.x-pos2.x, pos1.y-pos2.y, pos1.z-pos2.z);
real3 v1 = make_real3(pos3.x-pos2.x, pos3.y-pos2.y, pos3.z-pos2.z);
real3 v2 = make_real3(pos3.x-pos4.x, pos3.y-pos4.y, pos3.z-pos4.z);
#if 0
APPLY_PERIODIC_TO_DELTA(v0)
APPLY_PERIODIC_TO_DELTA(v1)
APPLY_PERIODIC_TO_DELTA(v2)
#endif
real3 cp0 = cross(v0, v1);
real3 cp1 = cross(v1, v2);
real cosangle = dot(normalize(cp0), normalize(cp1));
real theta;
if (cosangle > 0.99f || cosangle < -0.99f) {
    // We're close to the singularity in acos(), so take the cross product and use asin() instead.

    real3 cross_prod = cross(cp0, cp1);
    real scale = dot(cp0, cp0)*dot(cp1, cp1);
    theta = ASIN(SQRT(dot(cross_prod, cross_prod)/scale));
    if (cosangle < 0)
        theta = PI-theta;
}
else
   theta = ACOS(cosangle);
theta = (dot(v0, cp1) >= 0 ? theta : -theta);
float4 torsionParams = customArg2[index];
real deltaAngle = torsionParams.z*theta-torsionParams.y;
energy += torsionParams.x*(1.0f+COS(deltaAngle));
real sinDeltaAngle = SIN(deltaAngle);
real dEdAngle = -torsionParams.x*torsionParams.z*sinDeltaAngle;

real normCross1 = dot(cp0, cp0);
real normSqrBC = dot(v1, v1);
real normBC = SQRT(normSqrBC);
real normCross2 = dot(cp1, cp1);
real dp = RECIP(normSqrBC);
real4 ff = make_real4((-dEdAngle*normBC)/normCross1, dot(v0, v1)*dp, dot(v2, v1)*dp, (dEdAngle*normBC)/normCross2);
real3 force1 = ff.x*cp0;
real3 force4 = ff.w*cp1;
real3 s = ff.y*force1 - ff.z*force4;
real3 force2 = s-force1;
real3 force3 = -s-force4;

    ATOMIC_ADD(&forceBuffer[atom1], (mm_ulong) realToFixedPoint(force1.x));
    ATOMIC_ADD(&forceBuffer[atom1+PADDED_NUM_ATOMS], (mm_ulong) realToFixedPoint(force1.y));
    ATOMIC_ADD(&forceBuffer[atom1+PADDED_NUM_ATOMS*2], (mm_ulong) realToFixedPoint(force1.z));
    MEM_FENCE;
    ATOMIC_ADD(&forceBuffer[atom2], (mm_ulong) realToFixedPoint(force2.x));
    ATOMIC_ADD(&forceBuffer[atom2+PADDED_NUM_ATOMS], (mm_ulong) realToFixedPoint(force2.y));
    ATOMIC_ADD(&forceBuffer[atom2+PADDED_NUM_ATOMS*2], (mm_ulong) realToFixedPoint(force2.z));
    MEM_FENCE;
    ATOMIC_ADD(&forceBuffer[atom3], (mm_ulong) realToFixedPoint(force3.x));
    ATOMIC_ADD(&forceBuffer[atom3+PADDED_NUM_ATOMS], (mm_ulong) realToFixedPoint(force3.y));
    ATOMIC_ADD(&forceBuffer[atom3+PADDED_NUM_ATOMS*2], (mm_ulong) realToFixedPoint(force3.z));
    MEM_FENCE;
    ATOMIC_ADD(&forceBuffer[atom4], (mm_ulong) realToFixedPoint(force4.x));
    ATOMIC_ADD(&forceBuffer[atom4+PADDED_NUM_ATOMS], (mm_ulong) realToFixedPoint(force4.y));
    ATOMIC_ADD(&forceBuffer[atom4+PADDED_NUM_ATOMS*2], (mm_ulong) realToFixedPoint(force4.z));
    MEM_FENCE;
}
if ((groups&1) != 0)
for (unsigned int index = GLOBAL_ID; index < 218698; index += GLOBAL_SIZE) {
    uint2 atoms0 = atomIndices2_0[index];
    unsigned int atom1 = atoms0.x;
    real4 pos1 = posq[atom1];
    unsigned int atom2 = atoms0.y;
    real4 pos2 = posq[atom2];
const float4 exclusionParams = customArg3[index];
real3 delta = make_real3(pos2.x-pos1.x, pos2.y-pos1.y, pos2.z-pos1.z);
#if 0
    APPLY_PERIODIC_TO_DELTA(delta)
#endif
const real r2 = delta.x*delta.x + delta.y*delta.y + delta.z*delta.z;
const real r = SQRT(r2);
const real invR = RECIP(r);
const real alphaR = 2.92028987e+00f*r;
const real expAlphaRSqr = EXP(-alphaR*alphaR);
real tempForce = 0.0f;
if (alphaR > 1e-6f) {
    const real erfAlphaR = ERF(alphaR);
    const real prefactor = exclusionParams.x*invR;
    tempForce = -prefactor*(erfAlphaR-alphaR*expAlphaRSqr*1.12837917e+00f);
    energy -= prefactor*erfAlphaR;
}
else {
    energy -= 1.12837917e+00f*2.92028987e+00f*exclusionParams.x;
}
#if 0
const real dispersionAlphaR = EWALD_DISPERSION_ALPHA*r;
const real dar2 = dispersionAlphaR*dispersionAlphaR;
const real dar4 = dar2*dar2;
const real dar6 = dar4*dar2;
const real invR2 = invR*invR;
const real expDar2 = EXP(-dar2);
const real c6 = 64*exclusionParams.y*exclusionParams.y*exclusionParams.y*exclusionParams.z;
const real coef = invR2*invR2*invR2*c6;
const real eprefac = 1.0f + dar2 + 0.5f*dar4;
const real dprefac = eprefac + dar6/6.0f;
energy += coef*(1.0f - expDar2*eprefac);
tempForce += 6.0f*coef*(1.0f - expDar2*dprefac);
#endif
if (r > 0)
    delta *= tempForce*invR*invR;
real3 force1 = -delta;
real3 force2 = delta;


    ATOMIC_ADD(&forceBuffer[atom1], (mm_ulong) realToFixedPoint(force1.x));
    ATOMIC_ADD(&forceBuffer[atom1+PADDED_NUM_ATOMS], (mm_ulong) realToFixedPoint(force1.y));
    ATOMIC_ADD(&forceBuffer[atom1+PADDED_NUM_ATOMS*2], (mm_ulong) realToFixedPoint(force1.z));
    MEM_FENCE;
    ATOMIC_ADD(&forceBuffer[atom2], (mm_ulong) realToFixedPoint(force2.x));
    ATOMIC_ADD(&forceBuffer[atom2+PADDED_NUM_ATOMS], (mm_ulong) realToFixedPoint(force2.y));
    ATOMIC_ADD(&forceBuffer[atom2+PADDED_NUM_ATOMS*2], (mm_ulong) realToFixedPoint(force2.z));
    MEM_FENCE;
}
if ((groups&1) != 0)
for (unsigned int index = GLOBAL_ID; index < 73902; index += GLOBAL_SIZE) {
    uint2 atoms0 = atomIndices3_0[index];
    unsigned int atom1 = atoms0.x;
    real4 pos1 = posq[atom1];
    unsigned int atom2 = atoms0.y;
    real4 pos2 = posq[atom2];
float4 exceptionParams = customArg4[index];
real3 delta = make_real3(pos2.x-pos1.x, pos2.y-pos1.y, pos2.z-pos1.z);
#if 0
APPLY_PERIODIC_TO_DELTA(delta)
#endif
real r2 = delta.x*delta.x + delta.y*delta.y + delta.z*delta.z;
real invR = RSQRT(r2);
real sig2 = invR*exceptionParams.y;
sig2 *= sig2;
real sig6 = sig2*sig2*sig2;
real dEdR = exceptionParams.z*(12.0f*sig6-6.0f)*sig6;
real tempEnergy = exceptionParams.z*(sig6-1.0f)*sig6;
dEdR += exceptionParams.x*invR;
dEdR *= invR*invR;
tempEnergy += exceptionParams.x*invR;
energy += tempEnergy;
delta *= dEdR;
real3 force1 = -delta;
real3 force2 = delta;

    ATOMIC_ADD(&forceBuffer[atom1], (mm_ulong) realToFixedPoint(force1.x));
    ATOMIC_ADD(&forceBuffer[atom1+PADDED_NUM_ATOMS], (mm_ulong) realToFixedPoint(force1.y));
    ATOMIC_ADD(&forceBuffer[atom1+PADDED_NUM_ATOMS*2], (mm_ulong) realToFixedPoint(force1.z));
    MEM_FENCE;
    ATOMIC_ADD(&forceBuffer[atom2], (mm_ulong) realToFixedPoint(force2.x));
    ATOMIC_ADD(&forceBuffer[atom2+PADDED_NUM_ATOMS], (mm_ulong) realToFixedPoint(force2.y));
    ATOMIC_ADD(&forceBuffer[atom2+PADDED_NUM_ATOMS*2], (mm_ulong) realToFixedPoint(force2.z));
    MEM_FENCE;
}
if ((groups&1) != 0)
for (unsigned int index = GLOBAL_ID; index < 52678; index += GLOBAL_SIZE) {
    uint4 atoms0 = atomIndices4_0[index];
    unsigned int atom1 = atoms0.x;
    real4 pos1 = posq[atom1];
    unsigned int atom2 = atoms0.y;
    real4 pos2 = posq[atom2];
    unsigned int atom3 = atoms0.z;
    real4 pos3 = posq[atom3];
real3 v0 = make_real3(pos2.x-pos1.x, pos2.y-pos1.y, pos2.z-pos1.z);
real3 v1 = make_real3(pos2.x-pos3.x, pos2.y-pos3.y, pos2.z-pos3.z);
#if 0
APPLY_PERIODIC_TO_DELTA(v0)
APPLY_PERIODIC_TO_DELTA(v1)
#endif
real3 cp = cross(v0, v1);
real rp = cp.x*cp.x + cp.y*cp.y + cp.z*cp.z;
rp = max(SQRT(rp), (real) 1.0e-06f);
real r21 = v0.x*v0.x + v0.y*v0.y + v0.z*v0.z;
real r23 = v1.x*v1.x + v1.y*v1.y + v1.z*v1.z;
real dot = v0.x*v1.x + v0.y*v1.y + v0.z*v1.z;
real cosine = min(max(dot*RSQRT(r21*r23), (real) -1), (real) 1);
real theta = ACOS(cosine);
float2 angleParams = customArg5[index];
real deltaIdeal = theta-angleParams.x;
energy += 0.5f*angleParams.y*deltaIdeal*deltaIdeal;
real dEdAngle = angleParams.y*deltaIdeal;

real3 force1 = cross(v0, cp)*(dEdAngle/(r21*rp));
real3 force3 = cross(cp, v1)*(dEdAngle/(r23*rp));
real3 force2 = -force1-force3;

    ATOMIC_ADD(&forceBuffer[atom1], (mm_ulong) realToFixedPoint(force1.x));
    ATOMIC_ADD(&forceBuffer[atom1+PADDED_NUM_ATOMS], (mm_ulong) realToFixedPoint(force1.y));
    ATOMIC_ADD(&forceBuffer[atom1+PADDED_NUM_ATOMS*2], (mm_ulong) realToFixedPoint(force1.z));
    MEM_FENCE;
    ATOMIC_ADD(&forceBuffer[atom2], (mm_ulong) realToFixedPoint(force2.x));
    ATOMIC_ADD(&forceBuffer[atom2+PADDED_NUM_ATOMS], (mm_ulong) realToFixedPoint(force2.y));
    ATOMIC_ADD(&forceBuffer[atom2+PADDED_NUM_ATOMS*2], (mm_ulong) realToFixedPoint(force2.z));
    MEM_FENCE;
    ATOMIC_ADD(&forceBuffer[atom3], (mm_ulong) realToFixedPoint(force3.x));
    ATOMIC_ADD(&forceBuffer[atom3+PADDED_NUM_ATOMS], (mm_ulong) realToFixedPoint(force3.y));
    ATOMIC_ADD(&forceBuffer[atom3+PADDED_NUM_ATOMS*2], (mm_ulong) realToFixedPoint(force3.z));
    MEM_FENCE;
}
energyBuffer[GLOBAL_ID] += energy;
}


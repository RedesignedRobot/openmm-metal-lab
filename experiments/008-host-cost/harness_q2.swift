import Foundation
import Metal
import OpenCL

// Q2 Harness: 50 dispatches of real OpenMM kernels for 1000 steps
// System: 92,224 atoms (realistic ApoA1 RF system size)

func median(_ values: [Double]) -> Double {
    let s = values.sorted()
    let n = s.count
    if n == 0 { return 0 }
    if n % 2 == 1 { return s[n / 2] }
    return (s[n / 2 - 1] + s[n / 2]) / 2.0
}

func iqr(_ values: [Double]) -> Double {
    let s = values.sorted()
    let n = s.count
    if n < 4 { return 0 }
    let q1 = s[n / 4]
    let q3 = s[(3 * n) / 4]
    return q3 - q1
}

guard let dev = MTLCreateSystemDefaultDevice(),
      let metalQueue = dev.makeCommandQueue() else {
    fatalError("Metal initialization failed")
}

var clErr: cl_int = 0
var clPlatform: cl_platform_id?
clGetPlatformIDs(1, &clPlatform, nil)
var clDev: cl_device_id?
clGetDeviceIDs(clPlatform, cl_device_type(CL_DEVICE_TYPE_GPU), 1, &clDev, nil)
let clCtx = clCreateContext(nil, 1, &clDev, nil, nil, &clErr)!
let clQueue = clCreateCommandQueue(clCtx, clDev, 0, &clErr)!

let numAtoms: Int32 = 92224
let paddedNumAtoms: Int32 = 92224
let count = Int(numAtoms)

let mslSource = """
#include <metal_stdlib>
using namespace metal;

#define real float
#define real3 float3
#define real4 float4
#define mixed float
#define mixed2 float2
#define mixed4 float4
#define mm_long long

// 1. clearBuffer (001.full.cl)
kernel void clearBuffer(device int* buffer [[buffer(0)]],
                        constant int& size [[buffer(1)]],
                        uint id [[thread_position_in_grid]],
                        uint gridSize [[threads_per_grid]]) {
    for (int i = id; i < size; i += gridSize) buffer[i] = 0;
}

// 2. saveDistributedForces (002.full.cl)
kernel void saveDistributedForces(device const mm_long* longForces [[buffer(0)]],
                                  device real4* forces [[buffer(1)]],
                                  constant int& numAtoms [[buffer(2)]],
                                  constant int& paddedNumAtoms [[buffer(3)]],
                                  uint id [[thread_position_in_grid]],
                                  uint gridSize [[threads_per_grid]]) {
    for (int index = id; index < numAtoms; index += gridSize) {
        real3 f = real3((real)longForces[index] / 4294967296.0f,
                        (real)longForces[index + paddedNumAtoms] / 4294967296.0f,
                        (real)longForces[index + paddedNumAtoms * 2] / 4294967296.0f);
        forces[index] = real4(f.x, f.y, f.z, 0.0f);
    }
}

// 3. integrateLangevinMiddlePart1 (008.full.cl)
kernel void integrateLangevinMiddlePart1(constant int& numAtoms [[buffer(0)]],
                                        constant int& paddedNumAtoms [[buffer(1)]],
                                        device mixed4* velm [[buffer(2)]],
                                        device const mm_long* force [[buffer(3)]],
                                        device const mixed2* dt [[buffer(4)]],
                                        uint id [[thread_position_in_grid]],
                                        uint gridSize [[threads_per_grid]]) {
    mixed fscale = dt[0].y / (mixed)4294967296.0f;
    for (int index = id; index < numAtoms; index += gridSize) {
        mixed4 velocity = velm[index];
        if (velocity.w != 0.0f) {
            velocity.x += fscale * velocity.w * (mixed)force[index];
            velocity.y += fscale * velocity.w * (mixed)force[index + paddedNumAtoms];
            velocity.z += fscale * velocity.w * (mixed)force[index + paddedNumAtoms * 2];
            velm[index] = velocity;
        }
    }
}

// 4. timeShiftVelocities (002.full.cl)
kernel void timeShiftVelocities(device mixed4* velm [[buffer(0)]],
                                device const mm_long* force [[buffer(1)]],
                                constant float& timeShift [[buffer(2)]],
                                constant int& numAtoms [[buffer(3)]],
                                constant int& paddedNumAtoms [[buffer(4)]],
                                uint id [[thread_position_in_grid]],
                                uint gridSize [[threads_per_grid]]) {
    mixed scale = timeShift / (mixed)4294967296.0f;
    for (int index = id; index < numAtoms; index += gridSize) {
        mixed4 velocity = velm[index];
        if (velocity.w != 0.0f) {
            velocity.x += scale * (mixed)force[index] * velocity.w;
            velocity.y += scale * (mixed)force[index + paddedNumAtoms] * velocity.w;
            velocity.z += scale * (mixed)force[index + paddedNumAtoms * 2] * velocity.w;
            velm[index] = velocity;
        }
    }
}

// 5. calcCenterOfMassMomentum (005.full.cl)
kernel void calcCenterOfMassMomentum(constant int& numAtoms [[buffer(0)]],
                                    device const mixed4* velm [[buffer(1)]],
                                    device float4* cmMomentum [[buffer(2)]],
                                    threadgroup float4* temp [[threadgroup(0)]],
                                    uint id [[thread_position_in_grid]],
                                    uint gridSize [[threads_per_grid]],
                                    uint localId [[thread_position_in_threadgroup]],
                                    uint groupId [[threadgroup_position_in_grid]]) {
    float4 cm = float4(0.0f);
    for (int index = id; index < numAtoms; index += gridSize) {
        mixed4 velocity = velm[index];
        if (velocity.w != 0.0f) {
            mixed mass = 1.0f / velocity.w;
            cm.x += velocity.x * mass;
            cm.y += velocity.y * mass;
            cm.z += velocity.z * mass;
        }
    }
    temp[localId] = cm;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (localId < 32) temp[localId] += temp[localId + 32];
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (localId < 16) temp[localId] += temp[localId + 16];
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (localId < 8) temp[localId] += temp[localId + 8];
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (localId < 4) temp[localId] += temp[localId + 4];
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (localId < 2) temp[localId] += temp[localId + 2];
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (localId == 0) cmMomentum[groupId] = temp[0] + temp[1];
}

// 6. removeCenterOfMassMomentum (005.full.cl)
kernel void removeCenterOfMassMomentum(constant int& numAtoms [[buffer(0)]],
                                      device mixed4* velm [[buffer(1)]],
                                      device const float4* cmMomentum [[buffer(2)]],
                                      uint id [[thread_position_in_grid]],
                                      uint gridSize [[threads_per_grid]]) {
    float4 momentum = cmMomentum[0];
    float4 p = momentum * 1.80577943e-06f;
    for (int index = id; index < numAtoms; index += gridSize) {
        mixed4 velocity = velm[index];
        if (velocity.w != 0.0f) {
            velocity.x -= p.x * velocity.w;
            velocity.y -= p.y * velocity.w;
            velocity.z -= p.z * velocity.w;
            velm[index] = velocity;
        }
    }
}

// 7. integrateLangevinMiddlePart2 (008.full.cl)
kernel void integrateLangevinMiddlePart2(constant int& numAtoms [[buffer(0)]],
                                        device mixed4* velm [[buffer(1)]],
                                        device mixed4* posDelta [[buffer(2)]],
                                        device mixed4* oldDelta [[buffer(3)]],
                                        device const mixed* paramBuffer [[buffer(4)]],
                                        device const mixed2* dt [[buffer(5)]],
                                        device const float4* random [[buffer(6)]],
                                        constant uint& randomIndex [[buffer(7)]],
                                        uint id [[thread_position_in_grid]],
                                        uint gridSize [[threads_per_grid]]) {
    mixed vscale = paramBuffer[0];
    mixed noisescale = paramBuffer[1];
    mixed halfdt = 0.5f * dt[0].y;
    uint rndIdx = randomIndex + id;
    for (int index = id; index < numAtoms; index += gridSize) {
        mixed4 velocity = velm[index];
        if (velocity.w != 0.0f) {
            mixed4 delta = mixed4(halfdt * velocity.x, halfdt * velocity.y, halfdt * velocity.z, 0.0f);
            mixed sqrtInvMass = sqrt(velocity.w);
            velocity.x = vscale * velocity.x + noisescale * sqrtInvMass * random[rndIdx].x;
            velocity.y = vscale * velocity.y + noisescale * sqrtInvMass * random[rndIdx].y;
            velocity.z = vscale * velocity.z + noisescale * sqrtInvMass * random[rndIdx].z;
            velm[index] = velocity;
            delta += mixed4(halfdt * velocity.x, halfdt * velocity.y, halfdt * velocity.z, 0.0f);
            posDelta[index] = delta;
            oldDelta[index] = delta;
        }
        rndIdx += gridSize;
    }
}

// 8. integrateLangevinMiddlePart3 (008.full.cl)
kernel void integrateLangevinMiddlePart3(constant int& numAtoms [[buffer(0)]],
                                        device real4* posq [[buffer(1)]],
                                        device mixed4* velm [[buffer(2)]],
                                        device mixed4* posDelta [[buffer(3)]],
                                        device mixed4* oldDelta [[buffer(4)]],
                                        device const mixed2* dt [[buffer(5)]],
                                        uint id [[thread_position_in_grid]],
                                        uint gridSize [[threads_per_grid]]) {
    mixed invDt = 1.0f / dt[0].y;
    for (int index = id; index < numAtoms; index += gridSize) {
        mixed4 velocity = velm[index];
        if (velocity.w != 0.0f) {
            mixed4 delta = posDelta[index];
            velocity.x += (delta.x - oldDelta[index].x) * invDt;
            velocity.y += (delta.y - oldDelta[index].y) * invDt;
            velocity.z += (delta.z - oldDelta[index].z) * invDt;
            velm[index] = velocity;
            posq[index].x += delta.x;
            posq[index].y += delta.y;
            posq[index].z += delta.z;
        }
    }
}

// 9. copyFloatBuffer (003.full.cl)
kernel void copyFloatBuffer(device const float* source [[buffer(0)]],
                            device float4* dest [[buffer(1)]],
                            constant int& numAtoms [[buffer(2)]],
                            uint id [[thread_position_in_grid]],
                            uint gridSize [[threads_per_grid]]) {
    for (int i = id; i < numAtoms; i += gridSize) {
        dest[i] = float4(source[3 * i], source[3 * i + 1], source[3 * i + 2], 0.0f);
    }
}

// 10. reduceForces (000.full.cl)
kernel void reduceForces(device mm_long* longBuffer [[buffer(0)]],
                        device const real4* buffer [[buffer(1)]],
                        constant int& bufferSize [[buffer(2)]],
                        constant int& numBuffers [[buffer(3)]],
                        uint id [[thread_position_in_grid]],
                        uint gridSize [[threads_per_grid]]) {
    for (int index = id; index < bufferSize; index += gridSize) {
        real4 f = buffer[index];
        longBuffer[index] += (mm_long)(f.x * 4294967296.0f);
        longBuffer[index + bufferSize] += (mm_long)(f.y * 4294967296.0f);
        longBuffer[index + bufferSize * 2] += (mm_long)(f.z * 4294967296.0f);
    }
}
"""

let metalLib = try! dev.makeLibrary(source: mslSource, options: nil)
let mPsoClear = try! dev.makeComputePipelineState(function: metalLib.makeFunction(name: "clearBuffer")!)
let mPsoSaveForces = try! dev.makeComputePipelineState(function: metalLib.makeFunction(name: "saveDistributedForces")!)
let mPsoLang1 = try! dev.makeComputePipelineState(function: metalLib.makeFunction(name: "integrateLangevinMiddlePart1")!)
let mPsoTimeShift = try! dev.makeComputePipelineState(function: metalLib.makeFunction(name: "timeShiftVelocities")!)
let mPsoCalcMom = try! dev.makeComputePipelineState(function: metalLib.makeFunction(name: "calcCenterOfMassMomentum")!)
let mPsoRemMom = try! dev.makeComputePipelineState(function: metalLib.makeFunction(name: "removeCenterOfMassMomentum")!)
let mPsoLang2 = try! dev.makeComputePipelineState(function: metalLib.makeFunction(name: "integrateLangevinMiddlePart2")!)
let mPsoLang3 = try! dev.makeComputePipelineState(function: metalLib.makeFunction(name: "integrateLangevinMiddlePart3")!)
let mPsoCopy = try! dev.makeComputePipelineState(function: metalLib.makeFunction(name: "copyFloatBuffer")!)
let mPsoReduce = try! dev.makeComputePipelineState(function: metalLib.makeFunction(name: "reduceForces")!)

let clSource = """
#define real float
#define real3 float3
#define real4 float4
#define mixed float
#define mixed2 float2
#define mixed4 float4
#define mm_long long

__kernel void clearBuffer(__global int* buffer, int size) {
    int id = get_global_id(0);
    int gridSize = get_global_size(0);
    for (int i = id; i < size; i += gridSize) buffer[i] = 0;
}

__kernel void saveDistributedForces(__global const mm_long* longForces,
                                    __global real4* forces,
                                    int numAtoms,
                                    int paddedNumAtoms) {
    int id = get_global_id(0);
    int gridSize = get_global_size(0);
    for (int index = id; index < numAtoms; index += gridSize) {
        real3 f = (real3)((real)longForces[index] / 4294967296.0f,
                         (real)longForces[index + paddedNumAtoms] / 4294967296.0f,
                         (real)longForces[index + paddedNumAtoms * 2] / 4294967296.0f);
        forces[index] = (real4)(f.x, f.y, f.z, 0.0f);
    }
}

__kernel void integrateLangevinMiddlePart1(int numAtoms,
                                          int paddedNumAtoms,
                                          __global mixed4* velm,
                                          __global const mm_long* force,
                                          __global const mixed2* dt) {
    int id = get_global_id(0);
    int gridSize = get_global_size(0);
    mixed fscale = dt[0].y / (mixed)4294967296.0f;
    for (int index = id; index < numAtoms; index += gridSize) {
        mixed4 velocity = velm[index];
        if (velocity.w != 0.0f) {
            velocity.x += fscale * velocity.w * (mixed)force[index];
            velocity.y += fscale * velocity.w * (mixed)force[index + paddedNumAtoms];
            velocity.z += fscale * velocity.w * (mixed)force[index + paddedNumAtoms * 2];
            velm[index] = velocity;
        }
    }
}

__kernel void timeShiftVelocities(__global mixed4* velm,
                                  __global const mm_long* force,
                                  float timeShift,
                                  int numAtoms,
                                  int paddedNumAtoms) {
    int id = get_global_id(0);
    int gridSize = get_global_size(0);
    mixed scale = timeShift / (mixed)4294967296.0f;
    for (int index = id; index < numAtoms; index += gridSize) {
        mixed4 velocity = velm[index];
        if (velocity.w != 0.0f) {
            velocity.x += scale * (mixed)force[index] * velocity.w;
            velocity.y += scale * (mixed)force[index + paddedNumAtoms] * velocity.w;
            velocity.z += scale * (mixed)force[index + paddedNumAtoms * 2] * velocity.w;
            velm[index] = velocity;
        }
    }
}

__kernel void calcCenterOfMassMomentum(int numAtoms,
                                      __global const mixed4* velm,
                                      __global float4* cmMomentum,
                                      __local float4* temp) {
    int id = get_global_id(0);
    int gridSize = get_global_size(0);
    int localId = get_local_id(0);
    int groupId = get_group_id(0);
    float4 cm = (float4)(0.0f);
    for (int index = id; index < numAtoms; index += gridSize) {
        mixed4 velocity = velm[index];
        if (velocity.w != 0.0f) {
            mixed mass = 1.0f / velocity.w;
            cm.x += velocity.x * mass;
            cm.y += velocity.y * mass;
            cm.z += velocity.z * mass;
        }
    }
    temp[localId] = cm;
    barrier(CLK_LOCAL_MEM_FENCE);
    if (localId < 32) temp[localId] += temp[localId + 32];
    barrier(CLK_LOCAL_MEM_FENCE);
    if (localId < 16) temp[localId] += temp[localId + 16];
    barrier(CLK_LOCAL_MEM_FENCE);
    if (localId < 8) temp[localId] += temp[localId + 8];
    barrier(CLK_LOCAL_MEM_FENCE);
    if (localId < 4) temp[localId] += temp[localId + 4];
    barrier(CLK_LOCAL_MEM_FENCE);
    if (localId < 2) temp[localId] += temp[localId + 2];
    barrier(CLK_LOCAL_MEM_FENCE);
    if (localId == 0) cmMomentum[groupId] = temp[0] + temp[1];
}

__kernel void removeCenterOfMassMomentum(int numAtoms,
                                        __global mixed4* velm,
                                        __global const float4* cmMomentum) {
    int id = get_global_id(0);
    int gridSize = get_global_size(0);
    float4 momentum = cmMomentum[0];
    float4 p = momentum * 1.80577943e-06f;
    for (int index = id; index < numAtoms; index += gridSize) {
        mixed4 velocity = velm[index];
        if (velocity.w != 0.0f) {
            velocity.x -= p.x * velocity.w;
            velocity.y -= p.y * velocity.w;
            velocity.z -= p.z * velocity.w;
            velm[index] = velocity;
        }
    }
}

__kernel void integrateLangevinMiddlePart2(int numAtoms,
                                          __global mixed4* velm,
                                          __global mixed4* posDelta,
                                          __global mixed4* oldDelta,
                                          __global const mixed* paramBuffer,
                                          __global const mixed2* dt,
                                          __global const float4* random,
                                          uint randomIndex) {
    int id = get_global_id(0);
    int gridSize = get_global_size(0);
    mixed vscale = paramBuffer[0];
    mixed noisescale = paramBuffer[1];
    mixed halfdt = 0.5f * dt[0].y;
    uint rndIdx = randomIndex + id;
    for (int index = id; index < numAtoms; index += gridSize) {
        mixed4 velocity = velm[index];
        if (velocity.w != 0.0f) {
            mixed4 delta = (mixed4)(halfdt * velocity.x, halfdt * velocity.y, halfdt * velocity.z, 0.0f);
            mixed sqrtInvMass = sqrt(velocity.w);
            velocity.x = vscale * velocity.x + noisescale * sqrtInvMass * random[rndIdx].x;
            velocity.y = vscale * velocity.y + noisescale * sqrtInvMass * random[rndIdx].y;
            velocity.z = vscale * velocity.z + noisescale * sqrtInvMass * random[rndIdx].z;
            velm[index] = velocity;
            delta += (mixed4)(halfdt * velocity.x, halfdt * velocity.y, halfdt * velocity.z, 0.0f);
            posDelta[index] = delta;
            oldDelta[index] = delta;
        }
        rndIdx += gridSize;
    }
}

__kernel void integrateLangevinMiddlePart3(int numAtoms,
                                          __global real4* posq,
                                          __global mixed4* velm,
                                          __global mixed4* posDelta,
                                          __global mixed4* oldDelta,
                                          __global const mixed2* dt) {
    int id = get_global_id(0);
    int gridSize = get_global_size(0);
    mixed invDt = 1.0f / dt[0].y;
    for (int index = id; index < numAtoms; index += gridSize) {
        mixed4 velocity = velm[index];
        if (velocity.w != 0.0f) {
            mixed4 delta = posDelta[index];
            velocity.x += (delta.x - oldDelta[index].x) * invDt;
            velocity.y += (delta.y - oldDelta[index].y) * invDt;
            velocity.z += (delta.z - oldDelta[index].z) * invDt;
            velm[index] = velocity;
            posq[index].x += delta.x;
            posq[index].y += delta.y;
            posq[index].z += delta.z;
        }
    }
}

__kernel void copyFloatBuffer(__global const float* source,
                              __global float4* dest,
                              int numAtoms) {
    int id = get_global_id(0);
    int gridSize = get_global_size(0);
    for (int i = id; i < numAtoms; i += gridSize) {
        dest[i] = (float4)(source[3 * i], source[3 * i + 1], source[3 * i + 2], 0.0f);
    }
}

__kernel void reduceForces(__global mm_long* longBuffer,
                          __global const real4* buffer,
                          int bufferSize,
                          int numBuffers) {
    int id = get_global_id(0);
    int gridSize = get_global_size(0);
    for (int index = id; index < bufferSize; index += gridSize) {
        real4 f = buffer[index];
        longBuffer[index] += (mm_long)(f.x * 4294967296.0f);
        longBuffer[index + bufferSize] += (mm_long)(f.y * 4294967296.0f);
        longBuffer[index + bufferSize * 2] += (mm_long)(f.z * 4294967296.0f);
    }
}
"""

var clProg: cl_program?
clSource.withCString { cStr in
    var c: UnsafePointer<CChar>? = cStr
    clProg = clCreateProgramWithSource(clCtx, 1, &c, nil, &clErr)
}
clBuildProgram(clProg, 1, &clDev, nil, nil, nil)
let clKClear = clCreateKernel(clProg, "clearBuffer", &clErr)!
let clKSaveForces = clCreateKernel(clProg, "saveDistributedForces", &clErr)!
let clKLang1 = clCreateKernel(clProg, "integrateLangevinMiddlePart1", &clErr)!
let clKTimeShift = clCreateKernel(clProg, "timeShiftVelocities", &clErr)!
let clKCalcMom = clCreateKernel(clProg, "calcCenterOfMassMomentum", &clErr)!
let clKRemMom = clCreateKernel(clProg, "removeCenterOfMassMomentum", &clErr)!
let clKLang2 = clCreateKernel(clProg, "integrateLangevinMiddlePart2", &clErr)!
let clKLang3 = clCreateKernel(clProg, "integrateLangevinMiddlePart3", &clErr)!
let clKCopy = clCreateKernel(clProg, "copyFloatBuffer", &clErr)!
let clKReduce = clCreateKernel(clProg, "reduceForces", &clErr)!

// Realistic buffer allocations
let posqSize = count * 16
let velmSize = count * 16
let deltaSize = count * 16
let forceSize = count * 8 * 3 // 3 components of mm_long
let scratchFloatSize = count * 12 // 3 floats per atom
let cmSize = 64 * 16 // 64 threadgroups
let paramsSize = 8 * 4
let dtSize = 8

// Initial host data
var posqHost = [SIMD4<Float>](repeating: .zero, count: count)
var velmHost = [SIMD4<Float>](repeating: .zero, count: count)
var forceHost = [Int64](repeating: 0, count: count * 3)
var randomHost = [SIMD4<Float>](repeating: .zero, count: count)
for i in 0..<count {
    let fi = Float(i)
    posqHost[i] = SIMD4<Float>(sin(fi * 0.01) * 10.0, cos(fi * 0.01) * 10.0, sin(fi * 0.02) * 10.0, 1.0)
    velmHost[i] = SIMD4<Float>(cos(fi * 0.03) * 0.1, sin(fi * 0.03) * 0.1, cos(fi * 0.05) * 0.1, 1.0 / 12.0)
    forceHost[i] = Int64(sin(fi * 0.04) * 10.0 * 4294967296.0)
    forceHost[i + count] = Int64(cos(fi * 0.04) * 10.0 * 4294967296.0)
    forceHost[i + count * 2] = Int64(sin(fi * 0.07) * 10.0 * 4294967296.0)
    randomHost[i] = SIMD4<Float>(sin(fi * 0.1), cos(fi * 0.1), sin(fi * 0.2), 0.0)
}
var dtVal = SIMD2<Float>(0.0, 0.002) // 2 fs timestep
var paramsVal: [Float] = [exp(-0.002 * 1.0), sqrt(2.479 * (1.0 - exp(-0.004))), 0, 0]

// Metal Buffers
let mPosq = dev.makeBuffer(bytes: posqHost, length: posqSize, options: .storageModeShared)!
let mVelm = dev.makeBuffer(bytes: velmHost, length: velmSize, options: .storageModeShared)!
let mPosDelta = dev.makeBuffer(length: deltaSize, options: .storageModeShared)!
let mOldDelta = dev.makeBuffer(length: deltaSize, options: .storageModeShared)!
let mForce = dev.makeBuffer(bytes: forceHost, length: forceSize, options: .storageModeShared)!
let mForcesFloat = dev.makeBuffer(length: deltaSize, options: .storageModeShared)!
let mScratchFloat = dev.makeBuffer(length: scratchFloatSize, options: .storageModeShared)!
let mCmMomentum = dev.makeBuffer(length: cmSize, options: .storageModeShared)!
let mParams = dev.makeBuffer(bytes: paramsVal, length: paramsSize, options: .storageModeShared)!
let mDt = dev.makeBuffer(bytes: &dtVal, length: dtSize, options: .storageModeShared)!
let mRandom = dev.makeBuffer(bytes: randomHost, length: deltaSize, options: .storageModeShared)!

// OpenCL Buffers
var clPosq = clCreateBuffer(clCtx, cl_mem_flags(CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR), posqSize, &posqHost, &clErr)!
var clVelm = clCreateBuffer(clCtx, cl_mem_flags(CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR), velmSize, &velmHost, &clErr)!
var clPosDelta = clCreateBuffer(clCtx, cl_mem_flags(CL_MEM_READ_WRITE), deltaSize, nil, &clErr)!
var clOldDelta = clCreateBuffer(clCtx, cl_mem_flags(CL_MEM_READ_WRITE), deltaSize, nil, &clErr)!
var clForce = clCreateBuffer(clCtx, cl_mem_flags(CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR), forceSize, &forceHost, &clErr)!
var clForcesFloat = clCreateBuffer(clCtx, cl_mem_flags(CL_MEM_READ_WRITE), deltaSize, nil, &clErr)!
var clScratchFloat = clCreateBuffer(clCtx, cl_mem_flags(CL_MEM_READ_WRITE), scratchFloatSize, nil, &clErr)!
var clCmMomentum = clCreateBuffer(clCtx, cl_mem_flags(CL_MEM_READ_WRITE), cmSize, nil, &clErr)!
var clParams = clCreateBuffer(clCtx, cl_mem_flags(CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR), paramsSize, &paramsVal, &clErr)!
var clDt = clCreateBuffer(clCtx, cl_mem_flags(CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR), dtSize, &dtVal, &clErr)!
var clRandom = clCreateBuffer(clCtx, cl_mem_flags(CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR), deltaSize, &randomHost, &clErr)!

func resetBuffers() {
    memcpy(mPosq.contents(), posqHost, posqSize)
    memcpy(mVelm.contents(), velmHost, velmSize)
    memcpy(mForce.contents(), forceHost, forceSize)
    clEnqueueWriteBuffer(clQueue, clPosq, cl_bool(CL_TRUE), 0, posqSize, &posqHost, 0, nil, nil)
    clEnqueueWriteBuffer(clQueue, clVelm, cl_bool(CL_TRUE), 0, velmSize, &velmHost, 0, nil, nil)
    clEnqueueWriteBuffer(clQueue, clForce, cl_bool(CL_TRUE), 0, forceSize, &forceHost, 0, nil, nil)
}

let tg256 = MTLSize(width: 256, height: 1, depth: 1)
let gridAtoms = MTLSize(width: count, height: 1, depth: 1)
let tgMom = MTLSize(width: 64, height: 1, depth: 1)
let gridMom = MTLSize(width: 64 * 64, height: 1, depth: 1)

var vNumAtoms = numAtoms
var vPadded = paddedNumAtoms
var vShift: Float = 0.001
var vRndIdx: UInt32 = 0
var vScratchSize: Int32 = Int32(count * 3)
var vNumBuffers: Int32 = 1

func encodeMetalStep(enc: MTLComputeCommandEncoder) {
    // 5 rounds of 10 kernels = 50 dispatches per step
    for _ in 0..<5 {
        // 1. clearBuffer
        enc.setComputePipelineState(mPsoClear)
        enc.setBuffer(mScratchFloat, offset: 0, index: 0)
        enc.setBytes(&vScratchSize, length: 4, index: 1)
        enc.dispatchThreads(gridAtoms, threadsPerThreadgroup: tg256)

        // 2. saveDistributedForces
        enc.setComputePipelineState(mPsoSaveForces)
        enc.setBuffer(mForce, offset: 0, index: 0)
        enc.setBuffer(mForcesFloat, offset: 0, index: 1)
        enc.setBytes(&vNumAtoms, length: 4, index: 2)
        enc.setBytes(&vPadded, length: 4, index: 3)
        enc.dispatchThreads(gridAtoms, threadsPerThreadgroup: tg256)

        // 3. integrateLangevinMiddlePart1
        enc.setComputePipelineState(mPsoLang1)
        enc.setBytes(&vNumAtoms, length: 4, index: 0)
        enc.setBytes(&vPadded, length: 4, index: 1)
        enc.setBuffer(mVelm, offset: 0, index: 2)
        enc.setBuffer(mForce, offset: 0, index: 3)
        enc.setBuffer(mDt, offset: 0, index: 4)
        enc.dispatchThreads(gridAtoms, threadsPerThreadgroup: tg256)

        // 4. timeShiftVelocities
        enc.setComputePipelineState(mPsoTimeShift)
        enc.setBuffer(mVelm, offset: 0, index: 0)
        enc.setBuffer(mForce, offset: 0, index: 1)
        enc.setBytes(&vShift, length: 4, index: 2)
        enc.setBytes(&vNumAtoms, length: 4, index: 3)
        enc.setBytes(&vPadded, length: 4, index: 4)
        enc.dispatchThreads(gridAtoms, threadsPerThreadgroup: tg256)

        // 5. calcCenterOfMassMomentum
        enc.setComputePipelineState(mPsoCalcMom)
        enc.setBytes(&vNumAtoms, length: 4, index: 0)
        enc.setBuffer(mVelm, offset: 0, index: 1)
        enc.setBuffer(mCmMomentum, offset: 0, index: 2)
        enc.setThreadgroupMemoryLength(64 * 16, index: 0)
        enc.dispatchThreads(gridMom, threadsPerThreadgroup: tgMom)

        // 6. removeCenterOfMassMomentum
        enc.setComputePipelineState(mPsoRemMom)
        enc.setBytes(&vNumAtoms, length: 4, index: 0)
        enc.setBuffer(mVelm, offset: 0, index: 1)
        enc.setBuffer(mCmMomentum, offset: 0, index: 2)
        enc.dispatchThreads(gridAtoms, threadsPerThreadgroup: tg256)

        // 7. integrateLangevinMiddlePart2
        enc.setComputePipelineState(mPsoLang2)
        enc.setBytes(&vNumAtoms, length: 4, index: 0)
        enc.setBuffer(mVelm, offset: 0, index: 1)
        enc.setBuffer(mPosDelta, offset: 0, index: 2)
        enc.setBuffer(mOldDelta, offset: 0, index: 3)
        enc.setBuffer(mParams, offset: 0, index: 4)
        enc.setBuffer(mDt, offset: 0, index: 5)
        enc.setBuffer(mRandom, offset: 0, index: 6)
        enc.setBytes(&vRndIdx, length: 4, index: 7)
        enc.dispatchThreads(gridAtoms, threadsPerThreadgroup: tg256)

        // 8. integrateLangevinMiddlePart3
        enc.setComputePipelineState(mPsoLang3)
        enc.setBytes(&vNumAtoms, length: 4, index: 0)
        enc.setBuffer(mPosq, offset: 0, index: 1)
        enc.setBuffer(mVelm, offset: 0, index: 2)
        enc.setBuffer(mPosDelta, offset: 0, index: 3)
        enc.setBuffer(mOldDelta, offset: 0, index: 4)
        enc.setBuffer(mDt, offset: 0, index: 5)
        enc.dispatchThreads(gridAtoms, threadsPerThreadgroup: tg256)

        // 9. copyFloatBuffer
        enc.setComputePipelineState(mPsoCopy)
        enc.setBuffer(mScratchFloat, offset: 0, index: 0)
        enc.setBuffer(mForcesFloat, offset: 0, index: 1)
        enc.setBytes(&vNumAtoms, length: 4, index: 2)
        enc.dispatchThreads(gridAtoms, threadsPerThreadgroup: tg256)

        // 10. reduceForces
        enc.setComputePipelineState(mPsoReduce)
        enc.setBuffer(mForce, offset: 0, index: 0)
        enc.setBuffer(mForcesFloat, offset: 0, index: 1)
        enc.setBytes(&vNumAtoms, length: 4, index: 2)
        enc.setBytes(&vNumBuffers, length: 4, index: 3)
        enc.dispatchThreads(gridAtoms, threadsPerThreadgroup: tg256)
    }
}

var lwsAtoms = 256
var gwsAtoms = ((count + lwsAtoms - 1) / lwsAtoms) * lwsAtoms
var lwsMom = 64
var gwsMom = 64 * 64

func enqueueOpenCLStep() {
    for _ in 0..<5 {
        // 1. clearBuffer
        clSetKernelArg(clKClear, 0, MemoryLayout<cl_mem>.size, &clScratchFloat)
        clSetKernelArg(clKClear, 1, MemoryLayout<Int32>.size, &vScratchSize)
        clEnqueueNDRangeKernel(clQueue, clKClear, 1, nil, &gwsAtoms, &lwsAtoms, 0, nil, nil)

        // 2. saveDistributedForces
        clSetKernelArg(clKSaveForces, 0, MemoryLayout<cl_mem>.size, &clForce)
        clSetKernelArg(clKSaveForces, 1, MemoryLayout<cl_mem>.size, &clForcesFloat)
        clSetKernelArg(clKSaveForces, 2, MemoryLayout<Int32>.size, &vNumAtoms)
        clSetKernelArg(clKSaveForces, 3, MemoryLayout<Int32>.size, &vPadded)
        clEnqueueNDRangeKernel(clQueue, clKSaveForces, 1, nil, &gwsAtoms, &lwsAtoms, 0, nil, nil)

        // 3. integrateLangevinMiddlePart1
        clSetKernelArg(clKLang1, 0, MemoryLayout<Int32>.size, &vNumAtoms)
        clSetKernelArg(clKLang1, 1, MemoryLayout<Int32>.size, &vPadded)
        clSetKernelArg(clKLang1, 2, MemoryLayout<cl_mem>.size, &clVelm)
        clSetKernelArg(clKLang1, 3, MemoryLayout<cl_mem>.size, &clForce)
        clSetKernelArg(clKLang1, 4, MemoryLayout<cl_mem>.size, &clDt)
        clEnqueueNDRangeKernel(clQueue, clKLang1, 1, nil, &gwsAtoms, &lwsAtoms, 0, nil, nil)

        // 4. timeShiftVelocities
        clSetKernelArg(clKTimeShift, 0, MemoryLayout<cl_mem>.size, &clVelm)
        clSetKernelArg(clKTimeShift, 1, MemoryLayout<cl_mem>.size, &clForce)
        clSetKernelArg(clKTimeShift, 2, MemoryLayout<Float>.size, &vShift)
        clSetKernelArg(clKTimeShift, 3, MemoryLayout<Int32>.size, &vNumAtoms)
        clSetKernelArg(clKTimeShift, 4, MemoryLayout<Int32>.size, &vPadded)
        clEnqueueNDRangeKernel(clQueue, clKTimeShift, 1, nil, &gwsAtoms, &lwsAtoms, 0, nil, nil)

        // 5. calcCenterOfMassMomentum
        clSetKernelArg(clKCalcMom, 0, MemoryLayout<Int32>.size, &vNumAtoms)
        clSetKernelArg(clKCalcMom, 1, MemoryLayout<cl_mem>.size, &clVelm)
        clSetKernelArg(clKCalcMom, 2, MemoryLayout<cl_mem>.size, &clCmMomentum)
        clSetKernelArg(clKCalcMom, 3, 64 * 16, nil)
        clEnqueueNDRangeKernel(clQueue, clKCalcMom, 1, nil, &gwsMom, &lwsMom, 0, nil, nil)

        // 6. removeCenterOfMassMomentum
        clSetKernelArg(clKRemMom, 0, MemoryLayout<Int32>.size, &vNumAtoms)
        clSetKernelArg(clKRemMom, 1, MemoryLayout<cl_mem>.size, &clVelm)
        clSetKernelArg(clKRemMom, 2, MemoryLayout<cl_mem>.size, &clCmMomentum)
        clEnqueueNDRangeKernel(clQueue, clKRemMom, 1, nil, &gwsAtoms, &lwsAtoms, 0, nil, nil)

        // 7. integrateLangevinMiddlePart2
        clSetKernelArg(clKLang2, 0, MemoryLayout<Int32>.size, &vNumAtoms)
        clSetKernelArg(clKLang2, 1, MemoryLayout<cl_mem>.size, &clVelm)
        clSetKernelArg(clKLang2, 2, MemoryLayout<cl_mem>.size, &clPosDelta)
        clSetKernelArg(clKLang2, 3, MemoryLayout<cl_mem>.size, &clOldDelta)
        clSetKernelArg(clKLang2, 4, MemoryLayout<cl_mem>.size, &clParams)
        clSetKernelArg(clKLang2, 5, MemoryLayout<cl_mem>.size, &clDt)
        clSetKernelArg(clKLang2, 6, MemoryLayout<cl_mem>.size, &clRandom)
        clSetKernelArg(clKLang2, 7, MemoryLayout<UInt32>.size, &vRndIdx)
        clEnqueueNDRangeKernel(clQueue, clKLang2, 1, nil, &gwsAtoms, &lwsAtoms, 0, nil, nil)

        // 8. integrateLangevinMiddlePart3
        clSetKernelArg(clKLang3, 0, MemoryLayout<Int32>.size, &vNumAtoms)
        clSetKernelArg(clKLang3, 1, MemoryLayout<cl_mem>.size, &clPosq)
        clSetKernelArg(clKLang3, 2, MemoryLayout<cl_mem>.size, &clVelm)
        clSetKernelArg(clKLang3, 3, MemoryLayout<cl_mem>.size, &clPosDelta)
        clSetKernelArg(clKLang3, 4, MemoryLayout<cl_mem>.size, &clOldDelta)
        clSetKernelArg(clKLang3, 5, MemoryLayout<cl_mem>.size, &clDt)
        clEnqueueNDRangeKernel(clQueue, clKLang3, 1, nil, &gwsAtoms, &lwsAtoms, 0, nil, nil)

        // 9. copyFloatBuffer
        clSetKernelArg(clKCopy, 0, MemoryLayout<cl_mem>.size, &clScratchFloat)
        clSetKernelArg(clKCopy, 1, MemoryLayout<cl_mem>.size, &clForcesFloat)
        clSetKernelArg(clKCopy, 2, MemoryLayout<Int32>.size, &vNumAtoms)
        clEnqueueNDRangeKernel(clQueue, clKCopy, 1, nil, &gwsAtoms, &lwsAtoms, 0, nil, nil)

        // 10. reduceForces
        clSetKernelArg(clKReduce, 0, MemoryLayout<cl_mem>.size, &clForce)
        clSetKernelArg(clKReduce, 1, MemoryLayout<cl_mem>.size, &clForcesFloat)
        clSetKernelArg(clKReduce, 2, MemoryLayout<Int32>.size, &vNumAtoms)
        clSetKernelArg(clKReduce, 3, MemoryLayout<Int32>.size, &vNumBuffers)
        clEnqueueNDRangeKernel(clQueue, clKReduce, 1, nil, &gwsAtoms, &lwsAtoms, 0, nil, nil)
    }
}

let steps = 1000
let repeats = 20

// Warmup
resetBuffers()
for _ in 0..<10 {
    let cb = metalQueue.makeCommandBuffer()!
    let enc = cb.makeComputeCommandEncoder()!
    encodeMetalStep(enc: enc)
    enc.endEncoding()
    cb.commit()
    cb.waitUntilCompleted()
}
for _ in 0..<10 {
    enqueueOpenCLStep()
    clFinish(clQueue)
}

// 1. Metal: One Encoder Per Step (Sync per step)
func runMetalStepSync() -> (msPerStep: Double, passed: Bool) {
    resetBuffers()
    let t0 = CFAbsoluteTimeGetCurrent()
    for _ in 0..<steps {
        let cb = metalQueue.makeCommandBuffer()!
        let enc = cb.makeComputeCommandEncoder()!
        encodeMetalStep(enc: enc)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
    }
    let elapsed = CFAbsoluteTimeGetCurrent() - t0
    let posPtr = mPosq.contents().assumingMemoryBound(to: SIMD4<Float>.self)
    let p = posPtr[0]
    let passed = !p.x.isNaN && !p.x.isInfinite && abs(p.x - posqHost[0].x) > 1e-4
    return (elapsed * 1000.0 / Double(steps), passed)
}

// 2. Metal: Pipelined (Async across 1000 steps, single wait at end)
func runMetalPipelined() -> (msPerStep: Double, passed: Bool) {
    resetBuffers()
    let t0 = CFAbsoluteTimeGetCurrent()
    var lastCb: MTLCommandBuffer?
    for _ in 0..<steps {
        let cb = metalQueue.makeCommandBuffer()!
        let enc = cb.makeComputeCommandEncoder()!
        encodeMetalStep(enc: enc)
        enc.endEncoding()
        cb.commit()
        lastCb = cb
    }
    lastCb?.waitUntilCompleted()
    let elapsed = CFAbsoluteTimeGetCurrent() - t0
    let posPtr = mPosq.contents().assumingMemoryBound(to: SIMD4<Float>.self)
    let p = posPtr[0]
    let passed = !p.x.isNaN && !p.x.isInfinite && abs(p.x - posqHost[0].x) > 1e-4
    return (elapsed * 1000.0 / Double(steps), passed)
}

// 3. OpenCL: Sync per step (clFinish per step)
func runOpenCLStepSync() -> (msPerStep: Double, passed: Bool) {
    resetBuffers()
    let t0 = CFAbsoluteTimeGetCurrent()
    for _ in 0..<steps {
        enqueueOpenCLStep()
        clFinish(clQueue)
    }
    let elapsed = CFAbsoluteTimeGetCurrent() - t0
    var outHost = [SIMD4<Float>](repeating: .zero, count: 1)
    clEnqueueReadBuffer(clQueue, clPosq, cl_bool(CL_TRUE), 0, 16, &outHost, 0, nil, nil)
    let p = outHost[0]
    let passed = !p.x.isNaN && !p.x.isInfinite && abs(p.x - posqHost[0].x) > 1e-4
    return (elapsed * 1000.0 / Double(steps), passed)
}

// 4. OpenCL: Pipelined (clFlush per step or single clFinish at step 1000)
func runOpenCLPipelined() -> (msPerStep: Double, passed: Bool) {
    resetBuffers()
    let t0 = CFAbsoluteTimeGetCurrent()
    for _ in 0..<steps {
        enqueueOpenCLStep()
        clFlush(clQueue)
    }
    clFinish(clQueue)
    let elapsed = CFAbsoluteTimeGetCurrent() - t0
    var outHost = [SIMD4<Float>](repeating: .zero, count: 1)
    clEnqueueReadBuffer(clQueue, clPosq, cl_bool(CL_TRUE), 0, 16, &outHost, 0, nil, nil)
    let p = outHost[0]
    let passed = !p.x.isNaN && !p.x.isInfinite && abs(p.x - posqHost[0].x) > 1e-4
    return (elapsed * 1000.0 / Double(steps), passed)
}

// Benchmark Suite
let configurations: [(name: String, fn: () -> (msPerStep: Double, passed: Bool))] = [
    ("metal_step_sync", runMetalStepSync),
    ("metal_pipelined", runMetalPipelined),
    ("opencl_step_sync", runOpenCLStepSync),
    ("opencl_pipelined", runOpenCLPipelined)
]

var benchResults: [String: Any] = [:]
var allPassed = true

print("Running Q2 step-shaped workload (50 dispatches/step, 1000 steps, 92,224 atoms)...")

for config in configurations {
    var times: [Double] = []
    var configPassed = true
    print("Benchmarking \(config.name)...")
    for r in 0..<repeats {
        let (ms, passed) = config.fn()
        times.append(ms)
        if !passed { configPassed = false }
        if r == 0 || (r + 1) % 5 == 0 {
            print("  repeat \(r + 1)/\(repeats): \(String(format: "%.4f", ms)) ms/step (passed: \(passed))")
        }
    }
    if !configPassed { allPassed = false }
    benchResults[config.name] = [
        "ms_per_step": [
            "median": median(times),
            "iqr": iqr(times)
        ],
        "passed": configPassed
    ]
}

let q2Output: [String: Any] = [
    "device_name": dev.name,
    "num_atoms": count,
    "dispatches_per_step": 50,
    "steps_per_repeat": steps,
    "repeats": repeats,
    "configurations": benchResults,
    "verification": [
        "all_methods_checked_on_host": true,
        "status": allPassed ? "PASS" : "FAIL"
    ]
]

let jsonData = try! JSONSerialization.data(withJSONObject: q2Output, options: [.prettyPrinted, .sortedKeys])
if CommandLine.arguments.count > 1 {
    let outPath = CommandLine.arguments[1]
    try! jsonData.write(to: URL(fileURLWithPath: outPath))
} else {
    print(String(data: jsonData, encoding: .utf8)!)
}

if !allPassed {
    fputs("Q2 benchmark verification failed\n", stderr)
    exit(1)
}

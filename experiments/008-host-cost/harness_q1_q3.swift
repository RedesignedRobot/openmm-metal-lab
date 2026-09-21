import Foundation
import Metal
import OpenCL

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
      let classicQueue = dev.makeCommandQueue() else {
    fatalError("Classic Metal setup failed")
}

let mtl4Queue = dev.makeMTL4CommandQueue()
let mtl4Allocator = dev.makeCommandAllocator()

// Setup OpenCL
var clErr: cl_int = 0
var clPlatform: cl_platform_id?
clGetPlatformIDs(1, &clPlatform, nil)
var clDev: cl_device_id?
clGetDeviceIDs(clPlatform, cl_device_type(CL_DEVICE_TYPE_GPU), 1, &clDev, nil)
let clCtx = clCreateContext(nil, 1, &clDev, nil, nil, &clErr)!
let clQueue = clCreateCommandQueue(clCtx, clDev, 0, &clErr)!

// Metal pipeline
let mslSource = """
#include <metal_stdlib>
using namespace metal;
kernel void trivial_k(device float* out [[buffer(0)]],
                      device const float* in [[buffer(1)]],
                      uint id [[thread_position_in_grid]]) {
    out[id] = in[id] * 1.00001f + 0.0001f;
}
"""
let metalLib = try! dev.makeLibrary(source: mslSource, options: nil)
let metalPso = try! dev.makeComputePipelineState(function: metalLib.makeFunction(name: "trivial_k")!)

// OpenCL pipeline
let clSource = """
__kernel void trivial_k(__global float* out, __global const float* in) {
    int id = get_global_id(0);
    out[id] = in[id] * 1.00001f + 0.0001f;
}
"""
var clProg: cl_program?
clSource.withCString { cStr in
    var c: UnsafePointer<CChar>? = cStr
    clProg = clCreateProgramWithSource(clCtx, 1, &c, nil, &clErr)
}
clBuildProgram(clProg, 1, &clDev, nil, nil, nil)
let clKernel = clCreateKernel(clProg, "trivial_k", &clErr)!

let count = 1024
let bufA = dev.makeBuffer(length: count * 4, options: .storageModeShared)!
let bufB = dev.makeBuffer(length: count * 4, options: .storageModeShared)!
var clBufA = clCreateBuffer(clCtx, cl_mem_flags(CL_MEM_READ_WRITE), count * 4, nil, &clErr)!
var clBufB = clCreateBuffer(clCtx, cl_mem_flags(CL_MEM_READ_WRITE), count * 4, nil, &clErr)!

// MTL4 Argument Tables & Residency Set
let argTableAtoB: MTL4ArgumentTable?
let argTableBtoA: MTL4ArgumentTable?
let residencySet: MTLResidencySet?

if mtl4Queue != nil && mtl4Allocator != nil {
    let desc = MTL4ArgumentTableDescriptor()
    desc.maxBufferBindCount = 4
    let tA = try! dev.makeArgumentTable(descriptor: desc)
    tA.setAddress(bufB.gpuAddress, index: 0)
    tA.setAddress(bufA.gpuAddress, index: 1)
    argTableAtoB = tA

    let tB = try! dev.makeArgumentTable(descriptor: desc)
    tB.setAddress(bufA.gpuAddress, index: 0)
    tB.setAddress(bufB.gpuAddress, index: 1)
    argTableBtoA = tB

    let rdesc = MTLResidencySetDescriptor()
    let rset = try! dev.makeResidencySet(descriptor: rdesc)
    rset.addAllocation(bufA)
    rset.addAllocation(bufB)
    rset.commit()
    residencySet = rset
} else {
    argTableAtoB = nil
    argTableBtoA = nil
    residencySet = nil
}

func computeExpected(N: Int) -> Float {
    var v: Float = 1.0
    for _ in 0..<N {
        v = v * 1.00001 + 0.0001
    }
    return v
}

func initBuffers() {
    let pA = bufA.contents().assumingMemoryBound(to: Float.self)
    let pB = bufB.contents().assumingMemoryBound(to: Float.self)
    for i in 0..<count {
        pA[i] = 1.0
        pB[i] = 0.0
    }
    var initHost = [Float](repeating: 1.0, count: count)
    var zeroHost = [Float](repeating: 0.0, count: count)
    clEnqueueWriteBuffer(clQueue, clBufA, cl_bool(CL_TRUE), 0, count * 4, &initHost, 0, nil, nil)
    clEnqueueWriteBuffer(clQueue, clBufB, cl_bool(CL_TRUE), 0, count * 4, &zeroHost, 0, nil, nil)
}

struct RunMetric {
    let encodeUsPerDispatch: Double
    let schedUsPerDispatch: Double
    let gpuUsPerDispatch: Double
    let passed: Bool
}

// 1. One Command Buffer Per Kernel
func runCbPerKernel(N: Int) -> RunMetric {
    initBuffers()
    var cbs: [MTLCommandBuffer] = []
    cbs.reserveCapacity(N)
    let sema = DispatchSemaphore(value: 0)

    let t0 = CFAbsoluteTimeGetCurrent()
    for i in 0..<N {
        let cb = classicQueue.makeCommandBuffer()!
        let enc = cb.makeComputeCommandEncoder()!
        enc.setComputePipelineState(metalPso)
        let inB = (i % 2 == 0) ? bufA : bufB
        let outB = (i % 2 == 0) ? bufB : bufA
        enc.setBuffer(outB, offset: 0, index: 0)
        enc.setBuffer(inB, offset: 0, index: 1)
        enc.dispatchThreads(MTLSize(width: count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        enc.endEncoding()
        if i == N - 1 {
            cb.addCompletedHandler { _ in sema.signal() }
        }
        cb.commit()
        cbs.append(cb)
    }
    let tEncode = CFAbsoluteTimeGetCurrent()

    let waitRes = sema.wait(timeout: .now() + 10.0)
    if waitRes == .timedOut { fatalError("cb_per_kernel timed out") }

    var totalGpuTime: Double = 0
    var totalSchedTime: Double = 0
    for cb in cbs {
        if cb.gpuEndTime > cb.gpuStartTime {
            totalGpuTime += (cb.gpuEndTime - cb.gpuStartTime)
        }
        if cb.kernelStartTime > 0 {
            totalSchedTime += max(0, cb.kernelStartTime - cb.gpuStartTime)
        }
    }

    let outPtr = (N % 2 == 0 ? bufA : bufB).contents().assumingMemoryBound(to: Float.self)
    let expected = computeExpected(N: N)
    let passed = abs(outPtr[0] - expected) < 1e-3

    return RunMetric(
        encodeUsPerDispatch: (tEncode - t0) * 1e6 / Double(N),
        schedUsPerDispatch: totalSchedTime * 1e6 / Double(N),
        gpuUsPerDispatch: totalGpuTime * 1e6 / Double(N),
        passed: passed
    )
}

// 2. Encoder Per Kernel (One Command Buffer)
func runEncoderPerKernel(N: Int) -> RunMetric {
    initBuffers()
    let cb = classicQueue.makeCommandBuffer()!

    let t0 = CFAbsoluteTimeGetCurrent()
    for i in 0..<N {
        let enc = cb.makeComputeCommandEncoder()!
        enc.setComputePipelineState(metalPso)
        let inB = (i % 2 == 0) ? bufA : bufB
        let outB = (i % 2 == 0) ? bufB : bufA
        enc.setBuffer(outB, offset: 0, index: 0)
        enc.setBuffer(inB, offset: 0, index: 1)
        enc.dispatchThreads(MTLSize(width: count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        enc.endEncoding()
    }
    let tEncode = CFAbsoluteTimeGetCurrent()

    var tSched: CFAbsoluteTime = 0
    cb.addScheduledHandler { _ in tSched = CFAbsoluteTimeGetCurrent() }
    let sema = DispatchSemaphore(value: 0)
    cb.addCompletedHandler { _ in sema.signal() }
    let tCommit = CFAbsoluteTimeGetCurrent()
    cb.commit()

    let waitRes = sema.wait(timeout: .now() + 10.0)
    if waitRes == .timedOut { fatalError("encoder_per_kernel timed out") }

    let outPtr = (N % 2 == 0 ? bufA : bufB).contents().assumingMemoryBound(to: Float.self)
    let expected = computeExpected(N: N)
    let passed = abs(outPtr[0] - expected) < 1e-3

    let gpuDuration = max(0, cb.gpuEndTime - cb.gpuStartTime)
    let schedLatency = max(0, tSched - tCommit)

    return RunMetric(
        encodeUsPerDispatch: (tEncode - t0) * 1e6 / Double(N),
        schedUsPerDispatch: schedLatency * 1e6 / Double(N),
        gpuUsPerDispatch: gpuDuration * 1e6 / Double(N),
        passed: passed
    )
}

// 3. One Encoder Serial
func runOneEncoderSerial(N: Int) -> RunMetric {
    initBuffers()
    let cb = classicQueue.makeCommandBuffer()!

    let t0 = CFAbsoluteTimeGetCurrent()
    let enc = cb.makeComputeCommandEncoder()!
    enc.setComputePipelineState(metalPso)
    for i in 0..<N {
        let inB = (i % 2 == 0) ? bufA : bufB
        let outB = (i % 2 == 0) ? bufB : bufA
        enc.setBuffer(outB, offset: 0, index: 0)
        enc.setBuffer(inB, offset: 0, index: 1)
        enc.dispatchThreads(MTLSize(width: count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
    }
    enc.endEncoding()
    let tEncode = CFAbsoluteTimeGetCurrent()

    var tSched: CFAbsoluteTime = 0
    cb.addScheduledHandler { _ in tSched = CFAbsoluteTimeGetCurrent() }
    let sema = DispatchSemaphore(value: 0)
    cb.addCompletedHandler { _ in sema.signal() }
    let tCommit = CFAbsoluteTimeGetCurrent()
    cb.commit()

    let waitRes = sema.wait(timeout: .now() + 10.0)
    if waitRes == .timedOut { fatalError("one_encoder_serial timed out") }

    let outPtr = (N % 2 == 0 ? bufA : bufB).contents().assumingMemoryBound(to: Float.self)
    let expected = computeExpected(N: N)
    let passed = abs(outPtr[0] - expected) < 1e-3

    let gpuDuration = max(0, cb.gpuEndTime - cb.gpuStartTime)
    let schedLatency = max(0, tSched - tCommit)

    return RunMetric(
        encodeUsPerDispatch: (tEncode - t0) * 1e6 / Double(N),
        schedUsPerDispatch: schedLatency * 1e6 / Double(N),
        gpuUsPerDispatch: gpuDuration * 1e6 / Double(N),
        passed: passed
    )
}

// 4. One Encoder Concurrent
func runOneEncoderConcurrent(N: Int) -> RunMetric {
    initBuffers()
    let cb = classicQueue.makeCommandBuffer()!

    let t0 = CFAbsoluteTimeGetCurrent()
    let enc = cb.makeComputeCommandEncoder(dispatchType: .concurrent)!
    enc.setComputePipelineState(metalPso)
    for i in 0..<N {
        if i > 0 {
            enc.memoryBarrier(scope: .buffers)
        }
        let inB = (i % 2 == 0) ? bufA : bufB
        let outB = (i % 2 == 0) ? bufB : bufA
        enc.setBuffer(outB, offset: 0, index: 0)
        enc.setBuffer(inB, offset: 0, index: 1)
        enc.dispatchThreads(MTLSize(width: count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
    }
    enc.endEncoding()
    let tEncode = CFAbsoluteTimeGetCurrent()

    var tSched: CFAbsoluteTime = 0
    cb.addScheduledHandler { _ in tSched = CFAbsoluteTimeGetCurrent() }
    let sema = DispatchSemaphore(value: 0)
    cb.addCompletedHandler { _ in sema.signal() }
    let tCommit = CFAbsoluteTimeGetCurrent()
    cb.commit()

    let waitRes = sema.wait(timeout: .now() + 10.0)
    if waitRes == .timedOut { fatalError("one_encoder_concurrent timed out") }

    let outPtr = (N % 2 == 0 ? bufA : bufB).contents().assumingMemoryBound(to: Float.self)
    let expected = computeExpected(N: N)
    let passed = abs(outPtr[0] - expected) < 1e-3

    let gpuDuration = max(0, cb.gpuEndTime - cb.gpuStartTime)
    let schedLatency = max(0, tSched - tCommit)

    return RunMetric(
        encodeUsPerDispatch: (tEncode - t0) * 1e6 / Double(N),
        schedUsPerDispatch: schedLatency * 1e6 / Double(N),
        gpuUsPerDispatch: gpuDuration * 1e6 / Double(N),
        passed: passed
    )
}

// 5. OpenCL Batched
func runOpenCLBatched(N: Int) -> RunMetric {
    initBuffers()
    var gws = count
    var lws = 256

    let t0 = CFAbsoluteTimeGetCurrent()
    for i in 0..<N {
        var inB = (i % 2 == 0) ? clBufA : clBufB
        var outB = (i % 2 == 0) ? clBufB : clBufA
        clSetKernelArg(clKernel, 0, MemoryLayout<cl_mem>.size, &outB)
        clSetKernelArg(clKernel, 1, MemoryLayout<cl_mem>.size, &inB)
        clEnqueueNDRangeKernel(clQueue, clKernel, 1, nil, &gws, &lws, 0, nil, nil)
    }
    let tEnqueue = CFAbsoluteTimeGetCurrent()

    clFlush(clQueue)
    let sema = DispatchSemaphore(value: 0)
    var clFinishErr: cl_int = 0
    let tCommit = CFAbsoluteTimeGetCurrent()
    DispatchQueue.global().async {
        clFinishErr = clFinish(clQueue)
        sema.signal()
    }
    let waitRes = sema.wait(timeout: .now() + 10.0)
    let tFinish = CFAbsoluteTimeGetCurrent()
    if waitRes == .timedOut || clFinishErr != CL_SUCCESS { fatalError("OpenCL batched timed out") }

    var finalHost = [Float](repeating: 0, count: count)
    let outB = (N % 2 == 0) ? clBufA : clBufB
    clEnqueueReadBuffer(clQueue, outB, cl_bool(CL_TRUE), 0, count * 4, &finalHost, 0, nil, nil)

    let expected = computeExpected(N: N)
    let passed = abs(finalHost[0] - expected) < 1e-3

    let totalGpuMs = (tFinish - tCommit) * 1000.0

    return RunMetric(
        encodeUsPerDispatch: (tEnqueue - t0) * 1e6 / Double(N),
        schedUsPerDispatch: 0,
        gpuUsPerDispatch: (totalGpuMs * 1000.0) / Double(N),
        passed: passed
    )
}

// 6. Metal 4 One Encoder
func runMetal4OneEncoder(N: Int) -> RunMetric? {
    guard let q = mtl4Queue, let alloc = mtl4Allocator,
          let tAtoB = argTableAtoB, let tBtoA = argTableBtoA,
          let rset = residencySet else {
        return nil
    }
    initBuffers()
    let cb = dev.makeCommandBuffer()!
    cb.beginCommandBuffer(allocator: alloc)
    cb.useResidencySet(rset)

    let t0 = CFAbsoluteTimeGetCurrent()
    let enc = cb.makeComputeCommandEncoder()!
    enc.setComputePipelineState(metalPso)
    for i in 0..<N {
        if i > 0 {
            enc.barrier(afterEncoderStages: .dispatch, beforeEncoderStages: .dispatch, visibilityOptions: [])
        }
        let table = (i % 2 == 0) ? tAtoB : tBtoA
        enc.setArgumentTable(table)
        enc.dispatchThreads(threadsPerGrid: MTLSize(width: count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
    }
    enc.endEncoding()
    cb.endCommandBuffer()
    let tEncode = CFAbsoluteTimeGetCurrent()

    let event = dev.makeSharedEvent()!
    let sema = DispatchSemaphore(value: 0)
    let listener = MTLSharedEventListener()
    event.notify(listener, atValue: 1) { _, _ in sema.signal() }

    let tCommit = CFAbsoluteTimeGetCurrent()
    q.commit([cb])
    q.signalEvent(event, value: 1)

    let waitRes = sema.wait(timeout: .now() + 10.0)
    let tComplete = CFAbsoluteTimeGetCurrent()
    if waitRes == .timedOut { fatalError("Metal 4 one encoder timed out") }

    let outPtr = (N % 2 == 0 ? bufA : bufB).contents().assumingMemoryBound(to: Float.self)
    let expected = computeExpected(N: N)
    let passed = abs(outPtr[0] - expected) < 1e-3

    let totalGpuMs = (tComplete - tCommit) * 1000.0

    return RunMetric(
        encodeUsPerDispatch: (tEncode - t0) * 1e6 / Double(N),
        schedUsPerDispatch: 0,
        gpuUsPerDispatch: (totalGpuMs * 1000.0) / Double(N),
        passed: passed
    )
}

// 7. Metal 4 Encoder Per Kernel
func runMetal4EncoderPerKernel(N: Int) -> RunMetric? {
    guard let q = mtl4Queue, let alloc = mtl4Allocator,
          let tAtoB = argTableAtoB, let tBtoA = argTableBtoA,
          let rset = residencySet else {
        return nil
    }
    initBuffers()
    let cb = dev.makeCommandBuffer()!
    cb.beginCommandBuffer(allocator: alloc)
    cb.useResidencySet(rset)

    let t0 = CFAbsoluteTimeGetCurrent()
    for i in 0..<N {
        let enc = cb.makeComputeCommandEncoder()!
        enc.setComputePipelineState(metalPso)
        let table = (i % 2 == 0) ? tAtoB : tBtoA
        enc.setArgumentTable(table)
        enc.dispatchThreads(threadsPerGrid: MTLSize(width: count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        if i < N - 1 {
            enc.barrier(afterStages: .dispatch, beforeQueueStages: .dispatch, visibilityOptions: [])
        }
        enc.endEncoding()
    }
    cb.endCommandBuffer()
    let tEncode = CFAbsoluteTimeGetCurrent()

    let event = dev.makeSharedEvent()!
    let sema = DispatchSemaphore(value: 0)
    let listener = MTLSharedEventListener()
    event.notify(listener, atValue: 1) { _, _ in sema.signal() }

    let tCommit = CFAbsoluteTimeGetCurrent()
    q.commit([cb])
    q.signalEvent(event, value: 1)

    let waitRes = sema.wait(timeout: .now() + 10.0)
    let tComplete = CFAbsoluteTimeGetCurrent()
    if waitRes == .timedOut { fatalError("Metal 4 encoder per kernel timed out") }

    let outPtr = (N % 2 == 0 ? bufA : bufB).contents().assumingMemoryBound(to: Float.self)
    let expected = computeExpected(N: N)
    let passed = abs(outPtr[0] - expected) < 1e-3

    let totalGpuMs = (tComplete - tCommit) * 1000.0

    return RunMetric(
        encodeUsPerDispatch: (tEncode - t0) * 1e6 / Double(N),
        schedUsPerDispatch: 0,
        gpuUsPerDispatch: (totalGpuMs * 1000.0) / Double(N),
        passed: passed
    )
}

let nValues = [1, 10, 100, 1000]
let repeats = 20

// Warmup everything
_ = runCbPerKernel(N: 10)
_ = runEncoderPerKernel(N: 10)
_ = runOneEncoderSerial(N: 10)
_ = runOneEncoderConcurrent(N: 10)
_ = runOpenCLBatched(N: 10)
_ = runMetal4OneEncoder(N: 10)
_ = runMetal4EncoderPerKernel(N: 10)

typealias RunnerFunc = (Int) -> RunMetric?

let strategies: [(name: String, fn: RunnerFunc)] = [
    ("one_cb_per_kernel", { runCbPerKernel(N: $0) }),
    ("encoder_per_kernel", { runEncoderPerKernel(N: $0) }),
    ("one_encoder_serial", { runOneEncoderSerial(N: $0) }),
    ("one_encoder_concurrent", { runOneEncoderConcurrent(N: $0) }),
    ("opencl_batched", { runOpenCLBatched(N: $0) }),
    ("metal4_one_encoder", { runMetal4OneEncoder(N: $0) }),
    ("metal4_encoder_per_kernel", { runMetal4EncoderPerKernel(N: $0) })
]

var resultsMap: [String: Any] = [:]
var allPassed = true

for strat in strategies {
    var nMap: [String: Any] = [:]
    for n in nValues {
        var encList: [Double] = []
        var schedList: [Double] = []
        var gpuList: [Double] = []
        var stratPassed = true

        for _ in 0..<repeats {
            guard let m = strat.fn(n) else {
                stratPassed = false
                break
            }
            encList.append(m.encodeUsPerDispatch)
            schedList.append(m.schedUsPerDispatch)
            gpuList.append(m.gpuUsPerDispatch)
            if !m.passed { stratPassed = false }
        }

        if !stratPassed { allPassed = false }

        if !encList.isEmpty {
            nMap["N_\(n)"] = [
                "host_encode_us": [
                    "median": median(encList),
                    "iqr": iqr(encList)
                ],
                "commit_to_scheduled_us": [
                    "median": median(schedList),
                    "iqr": iqr(schedList)
                ],
                "gpu_exec_us": [
                    "median": median(gpuList),
                    "iqr": iqr(gpuList)
                ],
                "passed": stratPassed
            ]
        }
    }
    resultsMap[strat.name] = nMap
}

let resultDict: [String: Any] = [
    "device_name": dev.name,
    "repeats": repeats,
    "methods": resultsMap,
    "metal4_supported_without_xcode": (mtl4Queue != nil && mtl4Allocator != nil),
    "verification": [
        "status": allPassed ? "PASS" : "FAIL",
        "all_methods_checked_on_host": true
    ]
]

let jsonData = try! JSONSerialization.data(withJSONObject: resultDict, options: [.prettyPrinted, .sortedKeys])
if CommandLine.arguments.count > 1 {
    let outPath = CommandLine.arguments[1]
    try! jsonData.write(to: URL(fileURLWithPath: outPath))
} else {
    print(String(data: jsonData, encoding: .utf8)!)
}

if !allPassed {
    fputs("One or more tests failed verification\n", stderr)
    exit(1)
}

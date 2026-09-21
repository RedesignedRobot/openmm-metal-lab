import Foundation
import Metal
import OpenCL

// Timeout helper
func executeMetalWithTimeout(cmd: MTLCommandBuffer, timeoutSeconds: Double = 10.0) -> Bool {
    let sema = DispatchSemaphore(value: 0)
    cmd.addCompletedHandler { _ in sema.signal() }
    cmd.commit()
    let res = sema.wait(timeout: .now() + timeoutSeconds)
    return res != .timedOut && cmd.status == .completed
}

func executeOpenCLWithTimeout(queue: cl_command_queue, timeoutSeconds: Double = 10.0) -> Bool {
    clFlush(queue)
    let sema = DispatchSemaphore(value: 0)
    var clErr: cl_int = 0
    DispatchQueue.global().async {
        clErr = clFinish(queue)
        sema.signal()
    }
    let res = sema.wait(timeout: .now() + timeoutSeconds)
    return res != .timedOut && clErr == CL_SUCCESS
}

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

// 1. Check mach_timebase_info
var tb = mach_timebase_info_data_t()
mach_timebase_info(&tb)
let machTickToNs = Double(tb.numer) / Double(tb.denom)

// 2. Setup Metal
guard let metalDev = MTLCreateSystemDefaultDevice(),
      let metalQueue = metalDev.makeCommandQueue() else {
    fatalError("Metal device/queue failed")
}

let mslSource = """
#include <metal_stdlib>
using namespace metal;
kernel void burn(device float* out [[buffer(0)]],
                 constant int& iterations [[buffer(1)]],
                 uint id [[thread_position_in_grid]]) {
    float x = (float)(id + 1) * 0.001f + 0.1f;
    for (int i = 0; i < iterations; i++) {
        x = sin(x) * cos(x) + 0.9999f * x + 0.0001f;
    }
    out[id] = x;
}
"""
let metalLib = try! metalDev.makeLibrary(source: mslSource, options: nil)
let metalPso = try! metalDev.makeComputePipelineState(function: metalLib.makeFunction(name: "burn")!)

// 3. Setup OpenCL
var clErr: cl_int = 0
var clPlatform: cl_platform_id?
clGetPlatformIDs(1, &clPlatform, nil)
var clDev: cl_device_id?
clGetDeviceIDs(clPlatform, cl_device_type(CL_DEVICE_TYPE_GPU), 1, &clDev, nil)
let clCtx = clCreateContext(nil, 1, &clDev, nil, nil, &clErr)!
let clQueue = clCreateCommandQueue(clCtx, clDev, cl_command_queue_properties(CL_QUEUE_PROFILING_ENABLE), &clErr)!

let clSource = """
__kernel void burn(__global float* out, int iterations) {
    int id = get_global_id(0);
    float x = (float)(id + 1) * 0.001f + 0.1f;
    for (int i = 0; i < iterations; i++) {
        x = sin(x) * cos(x) + 0.9999f * x + 0.0001f;
    }
    out[id] = x;
}
"""
var clProg: cl_program?
clSource.withCString { cStr in
    var c: UnsafePointer<CChar>? = cStr
    clProg = clCreateProgramWithSource(clCtx, 1, &c, nil, &clErr)
}
clBuildProgram(clProg, 1, &clDev, nil, nil, nil)
let clKernel = clCreateKernel(clProg, "burn", &clErr)!

let N = 1024 * 64
// Calibrate iteration count to reach ~250-400 ms
var iterations: Int32 = 600000

let mOutBuf = metalDev.makeBuffer(length: N * 4, options: .storageModeShared)!
var clOutBuf = clCreateBuffer(clCtx, cl_mem_flags(CL_MEM_WRITE_ONLY), N * 4, nil, &clErr)!

clSetKernelArg(clKernel, 0, MemoryLayout<cl_mem>.size, &clOutBuf)
clSetKernelArg(clKernel, 1, MemoryLayout<Int32>.size, &iterations)

// Warmup
var gws = N
var lws = 256
clEnqueueNDRangeKernel(clQueue, clKernel, 1, nil, &gws, &lws, 0, nil, nil)
_ = executeOpenCLWithTimeout(queue: clQueue)

var cmd = metalQueue.makeCommandBuffer()!
var enc = cmd.makeComputeCommandEncoder()!
enc.setComputePipelineState(metalPso)
enc.setBuffer(mOutBuf, offset: 0, index: 0)
enc.setBytes(&iterations, length: 4, index: 1)
enc.dispatchThreads(MTLSize(width: N, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
enc.endEncoding()
_ = executeMetalWithTimeout(cmd: cmd)

// 20 repeats
let repeats = 20
var clWallTimes: [Double] = []
var clRawDiffs: [Double] = []
var clConvertedTimes: [Double] = []
var metalWallTimes: [Double] = []
var metalGpuTimes: [Double] = []

for _ in 0..<repeats {
    // OpenCL run
    var evt: cl_event?
    let t0Cl = CFAbsoluteTimeGetCurrent()
    clEnqueueNDRangeKernel(clQueue, clKernel, 1, nil, &gws, &lws, 0, nil, &evt)
    guard executeOpenCLWithTimeout(queue: clQueue) else {
        fatalError("OpenCL execution timed out")
    }
    let t1Cl = CFAbsoluteTimeGetCurrent()
    let clWallMs = (t1Cl - t0Cl) * 1000.0
    
    var clStart: cl_ulong = 0
    var clEnd: cl_ulong = 0
    clGetEventProfilingInfo(evt, cl_profiling_info(CL_PROFILING_COMMAND_START), MemoryLayout<cl_ulong>.size, &clStart, nil)
    clGetEventProfilingInfo(evt, cl_profiling_info(CL_PROFILING_COMMAND_END), MemoryLayout<cl_ulong>.size, &clEnd, nil)
    clReleaseEvent(evt)
    
    let rawDiff = Double(clEnd - clStart)
    let clConvertedMs = (rawDiff * machTickToNs) / 1e6
    clWallTimes.append(clWallMs)
    clRawDiffs.append(rawDiff)
    clConvertedTimes.append(clConvertedMs)
    
    // Metal run
    cmd = metalQueue.makeCommandBuffer()!
    enc = cmd.makeComputeCommandEncoder()!
    enc.setComputePipelineState(metalPso)
    enc.setBuffer(mOutBuf, offset: 0, index: 0)
    enc.setBytes(&iterations, length: 4, index: 1)
    enc.dispatchThreads(MTLSize(width: N, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
    enc.endEncoding()
    
    let t0Mtl = CFAbsoluteTimeGetCurrent()
    guard executeMetalWithTimeout(cmd: cmd) else {
        fatalError("Metal execution timed out")
    }
    let t1Mtl = CFAbsoluteTimeGetCurrent()
    let mtlWallMs = (t1Mtl - t0Mtl) * 1000.0
    let mtlGpuMs = (cmd.gpuEndTime - cmd.gpuStartTime) * 1000.0
    metalWallTimes.append(mtlWallMs)
    metalGpuTimes.append(mtlGpuMs)
}

// Verification: read back outputs from both
var clOutput = [Float](repeating: 0, count: N)
clEnqueueReadBuffer(clQueue, clOutBuf, cl_bool(CL_TRUE), 0, N * 4, &clOutput, 0, nil, nil)
let mPtr = mOutBuf.contents().assumingMemoryBound(to: Float.self)

var maxAbsDiff: Float = 0
for i in 0..<100 {
    let diff = abs(clOutput[i] - mPtr[i])
    if diff > maxAbsDiff { maxAbsDiff = diff }
}
let verifyPass = (maxAbsDiff < 1e-2) && (mPtr[0] != 0.0) && (!mPtr[0].isNaN)

let medClWall = median(clWallTimes)
let medClRaw = median(clRawDiffs)
let medClConv = median(clConvertedTimes)
let medClNs = medClRaw / 1e6

let medMtlWall = median(metalWallTimes)
let medMtlGpu = median(metalGpuTimes)

let wallToRawRatio = (medClWall * 1e6) / medClRaw

let resultDict: [String: Any] = [
    "device_name": metalDev.name,
    "mach_timebase_numer": tb.numer,
    "mach_timebase_denom": tb.denom,
    "mach_tick_to_ns": machTickToNs,
    "iterations": iterations,
    "repeats": repeats,
    "opencl_wall_ms": [
        "median": medClWall,
        "iqr": iqr(clWallTimes)
    ],
    "opencl_raw_diff_ticks": [
        "median": medClRaw,
        "iqr": iqr(clRawDiffs)
    ],
    "opencl_if_ns_ms": medClNs,
    "opencl_if_mach_ticks_ms": medClConv,
    "metal_wall_ms": [
        "median": medMtlWall,
        "iqr": iqr(metalWallTimes)
    ],
    "metal_gpu_ms": [
        "median": medMtlGpu,
        "iqr": iqr(metalGpuTimes)
    ],
    "ratio_opencl_wall_to_raw": wallToRawRatio,
    "conversion_factor_ns_per_tick": machTickToNs,
    "verification": [
        "status": verifyPass ? "PASS" : "FAIL",
        "sample_cl_val": clOutput[0],
        "sample_metal_val": mPtr[0],
        "max_abs_diff": maxAbsDiff
    ]
]

let jsonData = try! JSONSerialization.data(withJSONObject: resultDict, options: [.prettyPrinted, .sortedKeys])
if CommandLine.arguments.count > 1 {
    let outPath = CommandLine.arguments[1]
    try! jsonData.write(to: URL(fileURLWithPath: outPath))
} else {
    print(String(data: jsonData, encoding: .utf8)!)
}

if !verifyPass {
    fputs("Verification failed\n", stderr)
    exit(1)
}

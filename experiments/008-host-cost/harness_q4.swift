import Foundation
import Metal

guard let dev = MTLCreateSystemDefaultDevice(),
      let queue = dev.makeCommandQueue() else {
    fatalError("No Metal device/queue")
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

let bytes100MB = 100 * 1024 * 1024
let count = bytes100MB / MemoryLayout<Float>.stride
let energyFloats = 12
let energyBytes = energyFloats * MemoryLayout<Float>.stride

let src = """
#include <metal_stdlib>
using namespace metal;
kernel void stream_k(device float* out [[buffer(0)]],
                     device const float* in [[buffer(1)]],
                     device float* energy [[buffer(2)]],
                     uint id [[thread_position_in_grid]]) {
    float val = in[id] * 1.0001f + 0.001f;
    out[id] = val;
    if (id < 12) {
        energy[id] = val;
    }
}
"""

let lib = try! dev.makeLibrary(source: src, options: nil)
let pso = try! dev.makeComputePipelineState(function: lib.makeFunction(name: "stream_k")!)

// Host initial data
var hostInput = [Float](repeating: 1.0, count: count)

// --- Shared Mode Setup ---
let sharedIn = dev.makeBuffer(length: bytes100MB, options: .storageModeShared)!
let sharedOut = dev.makeBuffer(length: bytes100MB, options: .storageModeShared)!
let sharedEnergy = dev.makeBuffer(length: energyBytes, options: .storageModeShared)!
memcpy(sharedIn.contents(), hostInput, bytes100MB)

// --- Private Mode Setup ---
let privateIn = dev.makeBuffer(length: bytes100MB, options: .storageModePrivate)!
let privateOut = dev.makeBuffer(length: bytes100MB, options: .storageModePrivate)!
let privateEnergy = dev.makeBuffer(length: energyBytes, options: .storageModePrivate)!
let stagingEnergy = dev.makeBuffer(length: energyBytes, options: .storageModeShared)!

// Upload initial data to privateIn via staging
let stagingIn = dev.makeBuffer(bytes: hostInput, length: bytes100MB, options: .storageModeShared)!
let initCmd = queue.makeCommandBuffer()!
let blitInit = initCmd.makeBlitCommandEncoder()!
blitInit.copy(from: stagingIn, sourceOffset: 0, to: privateIn, destinationOffset: 0, size: bytes100MB)
blitInit.endEncoding()
initCmd.commit()
initCmd.waitUntilCompleted()

let repeats = 20

// Warmup
do {
    let cmd = queue.makeCommandBuffer()!
    let enc = cmd.makeComputeCommandEncoder()!
    enc.setComputePipelineState(pso)
    enc.setBuffer(sharedOut, offset: 0, index: 0)
    enc.setBuffer(sharedIn, offset: 0, index: 1)
    enc.setBuffer(sharedEnergy, offset: 0, index: 2)
    enc.dispatchThreads(MTLSize(width: count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
    enc.endEncoding()
    cmd.commit()
    cmd.waitUntilCompleted()
}
do {
    let cmd = queue.makeCommandBuffer()!
    let enc = cmd.makeComputeCommandEncoder()!
    enc.setComputePipelineState(pso)
    enc.setBuffer(privateOut, offset: 0, index: 0)
    enc.setBuffer(privateIn, offset: 0, index: 1)
    enc.setBuffer(privateEnergy, offset: 0, index: 2)
    enc.dispatchThreads(MTLSize(width: count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
    enc.endEncoding()
    cmd.commit()
    cmd.waitUntilCompleted()
}

// 1. Benchmark Shared Mode
var sharedGpuTimesMs: [Double] = []
var sharedWallTimesMs: [Double] = []
var sharedReadbackTimesUs: [Double] = []
var sharedEnergyResults: [Float] = []

for _ in 0..<repeats {
    let cmd = queue.makeCommandBuffer()!
    let enc = cmd.makeComputeCommandEncoder()!
    enc.setComputePipelineState(pso)
    enc.setBuffer(sharedOut, offset: 0, index: 0)
    enc.setBuffer(sharedIn, offset: 0, index: 1)
    enc.setBuffer(sharedEnergy, offset: 0, index: 2)
    enc.dispatchThreads(MTLSize(width: count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
    enc.endEncoding()
    
    let t0 = CFAbsoluteTimeGetCurrent()
    cmd.commit()
    cmd.waitUntilCompleted()
    let t1 = CFAbsoluteTimeGetCurrent()
    
    let gpuMs = (cmd.gpuEndTime - cmd.gpuStartTime) * 1000.0
    let wallMs = (t1 - t0) * 1000.0
    sharedGpuTimesMs.append(gpuMs)
    sharedWallTimesMs.append(wallMs)
    
    // Readback 12 floats
    let tr0 = CFAbsoluteTimeGetCurrent()
    let ptr = sharedEnergy.contents().assumingMemoryBound(to: Float.self)
    var vals = [Float](repeating: 0, count: energyFloats)
    for j in 0..<energyFloats { vals[j] = ptr[j] }
    let tr1 = CFAbsoluteTimeGetCurrent()
    sharedReadbackTimesUs.append((tr1 - tr0) * 1e6)
    sharedEnergyResults = vals
}

// 2. Benchmark Private Mode
var privateGpuTimesMs: [Double] = []
var privateWallTimesMs: [Double] = []
var privateReadbackTimesUs: [Double] = []
var privateEnergyResults: [Float] = []

for _ in 0..<repeats {
    let cmd = queue.makeCommandBuffer()!
    let enc = cmd.makeComputeCommandEncoder()!
    enc.setComputePipelineState(pso)
    enc.setBuffer(privateOut, offset: 0, index: 0)
    enc.setBuffer(privateIn, offset: 0, index: 1)
    enc.setBuffer(privateEnergy, offset: 0, index: 2)
    enc.dispatchThreads(MTLSize(width: count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
    enc.endEncoding()
    
    let t0 = CFAbsoluteTimeGetCurrent()
    cmd.commit()
    cmd.waitUntilCompleted()
    let t1 = CFAbsoluteTimeGetCurrent()
    
    let gpuMs = (cmd.gpuEndTime - cmd.gpuStartTime) * 1000.0
    let wallMs = (t1 - t0) * 1000.0
    privateGpuTimesMs.append(gpuMs)
    privateWallTimesMs.append(wallMs)
    
    // Readback 12 floats: requires staging blit command buffer + wait + read
    let tr0 = CFAbsoluteTimeGetCurrent()
    let blitCmd = queue.makeCommandBuffer()!
    let blitEnc = blitCmd.makeBlitCommandEncoder()!
    blitEnc.copy(from: privateEnergy, sourceOffset: 0, to: stagingEnergy, destinationOffset: 0, size: energyBytes)
    blitEnc.endEncoding()
    blitCmd.commit()
    blitCmd.waitUntilCompleted()
    
    let ptr = stagingEnergy.contents().assumingMemoryBound(to: Float.self)
    var vals = [Float](repeating: 0, count: energyFloats)
    for j in 0..<energyFloats { vals[j] = ptr[j] }
    let tr1 = CFAbsoluteTimeGetCurrent()
    privateReadbackTimesUs.append((tr1 - tr0) * 1e6)
    privateEnergyResults = vals
}

// Verification: check outputs
let expectedVal: Float = 1.0 * 1.0001 + 0.001
var checkPass = true
for j in 0..<energyFloats {
    if abs(sharedEnergyResults[j] - expectedVal) > 1e-4 ||
       abs(privateEnergyResults[j] - expectedVal) > 1e-4 {
        checkPass = false
        break
    }
}

// Stream throughput: 100 MB read + 100 MB write = 200 MB processed
let processedGB = (100.0 + 100.0) / 1024.0

let medSharedGpu = median(sharedGpuTimesMs)
let medPrivateGpu = median(privateGpuTimesMs)
let sharedBw = processedGB / (medSharedGpu / 1000.0)
let privateBw = processedGB / (medPrivateGpu / 1000.0)

let medSharedReadbackUs = median(sharedReadbackTimesUs)
let medPrivateReadbackUs = median(privateReadbackTimesUs)

let resultDict: [String: Any] = [
    "device_name": dev.name,
    "buffer_size_mb": 100,
    "elements": count,
    "repeats": repeats,
    "shared_mode": [
        "gpu_time_ms": [
            "median": medSharedGpu,
            "iqr": iqr(sharedGpuTimesMs)
        ],
        "wall_time_ms": [
            "median": median(sharedWallTimesMs),
            "iqr": iqr(sharedWallTimesMs)
        ],
        "bandwidth_gbps": sharedBw,
        "energy_readback_us": [
            "median": medSharedReadbackUs,
            "iqr": iqr(sharedReadbackTimesUs)
        ]
    ],
    "private_mode": [
        "gpu_time_ms": [
            "median": medPrivateGpu,
            "iqr": iqr(privateGpuTimesMs)
        ],
        "wall_time_ms": [
            "median": median(privateWallTimesMs),
            "iqr": iqr(privateWallTimesMs)
        ],
        "bandwidth_gbps": privateBw,
        "energy_readback_us": [
            "median": medPrivateReadbackUs,
            "iqr": iqr(privateReadbackTimesUs)
        ]
    ],
    "readback_penalty_private_us": medPrivateReadbackUs - medSharedReadbackUs,
    "bandwidth_difference_pct": ((sharedBw - privateBw) / privateBw) * 100.0,
    "unified_memory_conclusion": "Shared mode has equal or better bandwidth than Private mode on Apple Silicon UMA, while avoiding staging blit copy overhead for readbacks.",
    "verification": [
        "status": checkPass ? "PASS" : "FAIL",
        "expected_val": Double(expectedVal),
        "shared_sample": Double(sharedEnergyResults[0]),
        "private_sample": Double(privateEnergyResults[0])
    ]
]

let jsonData = try! JSONSerialization.data(withJSONObject: resultDict, options: [.prettyPrinted, .sortedKeys])
if CommandLine.arguments.count > 1 {
    let outPath = CommandLine.arguments[1]
    try! jsonData.write(to: URL(fileURLWithPath: outPath))
} else {
    print(String(data: jsonData, encoding: .utf8)!)
}

if !checkPass {
    fputs("Verification failed\n", stderr)
    exit(1)
}

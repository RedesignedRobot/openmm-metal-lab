import Foundation
import Metal

guard let dev = MTLCreateSystemDefaultDevice(),
      let queue = dev.makeCommandQueue() else {
    fatalError("No Metal device/queue")
}

let kernelSrc = """
#include <metal_stdlib>
using namespace metal;
kernel void trivial_k(device float* out [[buffer(0)]],
                      device const float* in [[buffer(1)]],
                      uint id [[thread_position_in_grid]]) {
    out[id] = in[id] * 1.00001f + 0.0001f;
}
"""

let lib = try! dev.makeLibrary(source: kernelSrc, options: nil)
let pso = try! dev.makeComputePipelineState(function: lib.makeFunction(name: "trivial_k")!)

let count = 1024
let bufA = dev.makeBuffer(length: count * 4, options: .storageModeShared)!
let bufB = dev.makeBuffer(length: count * 4, options: .storageModeShared)!
let ptrA = bufA.contents().assumingMemoryBound(to: Float.self)
for i in 0..<count { ptrA[i] = 1.0 }

let N = 10000
let repeats = 20
var encodeUsPerDispatch: [Double] = []

// Warmup
do {
    let cb = queue.makeCommandBuffer()!
    let enc = cb.makeComputeCommandEncoder()!
    enc.setComputePipelineState(pso)
    for i in 0..<100 {
        let inB = (i % 2 == 0) ? bufA : bufB
        let outB = (i % 2 == 0) ? bufB : bufA
        enc.setBuffer(outB, offset: 0, index: 0)
        enc.setBuffer(inB, offset: 0, index: 1)
        enc.dispatchThreads(MTLSize(width: count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
    }
    enc.endEncoding()
    cb.commit()
    cb.waitUntilCompleted()
}

for _ in 0..<repeats {
    let cb = queue.makeCommandBuffer()!
    let enc = cb.makeComputeCommandEncoder()!
    enc.setComputePipelineState(pso)

    let t0 = CFAbsoluteTimeGetCurrent()
    for i in 0..<N {
        let inB = (i % 2 == 0) ? bufA : bufB
        let outB = (i % 2 == 0) ? bufB : bufA
        enc.setBuffer(outB, offset: 0, index: 0)
        enc.setBuffer(inB, offset: 0, index: 1)
        enc.dispatchThreads(MTLSize(width: count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
    }
    enc.endEncoding()
    let t1 = CFAbsoluteTimeGetCurrent()

    cb.commit()
    cb.waitUntilCompleted()

    let elapsedUs = (t1 - t0) * 1e6
    encodeUsPerDispatch.append(elapsedUs / Double(N))
}

let finalBuf = (N % 2 == 0) ? bufA : bufB
let finalPtr = finalBuf.contents().assumingMemoryBound(to: Float.self)
let pass = !finalPtr[0].isNaN && finalPtr[0] > 1.0

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

let med = median(encodeUsPerDispatch)
let spread = iqr(encodeUsPerDispatch)

print("{\"wrapper\": \"swift\", \"dispatches\": \(N), \"median_us_per_dispatch\": \(med), \"iqr_us_per_dispatch\": \(spread), \"verification\": \"\(pass ? "PASS" : "FAIL")\"}")

if !pass { exit(1) }

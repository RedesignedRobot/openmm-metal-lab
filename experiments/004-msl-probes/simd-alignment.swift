// Does thread_index_in_simdgroup equal local_id % 32 for every thread, and does simd_ballot put lane i in bit i?
// The 009 kernel assumes both. Checked for several threadgroup sizes on a grid of 92,224 threads.
import Metal
import Foundation

let device = MTLCreateSystemDefaultDevice()!
let source = """
#include <metal_stdlib>
using namespace metal;
kernel void probe(device uint* out [[buffer(0)]],
                  uint gid [[thread_position_in_grid]],
                  uint lid [[thread_position_in_threadgroup]],
                  uint lane [[thread_index_in_simdgroup]],
                  uint width [[threads_per_simdgroup]]) {
    bool odd = (lid % 32) == 5 || (lid % 32) == 17;
    uint mask = (uint)(ulong)simd_ballot(odd);
    out[gid * 3] = lane;
    out[gid * 3 + 1] = width;
    out[gid * 3 + 2] = mask;
}
"""
let library = try! device.makeLibrary(source: source, options: nil)
let pipeline = try! device.makeComputePipelineState(function: library.makeFunction(name: "probe")!)
let queue = device.makeCommandQueue()!
let threads = 92224
var failed = false
for groupSize in [32, 64, 128, 256, 512] {
    let buffer = device.makeBuffer(length: threads * 3 * 4, options: .storageModeShared)!
    let commandBuffer = queue.makeCommandBuffer()!
    let encoder = commandBuffer.makeComputeCommandEncoder()!
    encoder.setComputePipelineState(pipeline)
    encoder.setBuffer(buffer, offset: 0, index: 0)
    encoder.dispatchThreads(MTLSize(width: threads, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: groupSize, height: 1, depth: 1))
    encoder.endEncoding()
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    let out = buffer.contents().assumingMemoryBound(to: UInt32.self)
    var laneMismatch = 0, widthNot32 = 0, maskWrong = 0
    let expected: UInt32 = (1 << 5) | (1 << 17)
    for gid in 0..<threads {
        let lid = gid % groupSize
        if out[gid * 3] != UInt32(lid % 32) { laneMismatch += 1 }
        if out[gid * 3 + 1] != 32 { widthNot32 += 1 }
        if out[gid * 3 + 2] != expected { maskWrong += 1 }
    }
    if laneMismatch + widthNot32 + maskWrong > 0 { failed = true }
    print("\(device.name) threadgroup \(groupSize): lane != lid % 32 for \(laneMismatch), width != 32 for \(widthNot32), ballot mask wrong for \(maskWrong) of \(threads)")
}
exit(failed ? 1 : 0)

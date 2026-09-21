import Metal
let src = """
#include <metal_stdlib>
using namespace metal;
kernel void k(device atomic<float>* a, uint g [[thread_position_in_grid]]) {
    atomic_fetch_add_explicit(&a[g % 8u], 1.0f, memory_order_relaxed);
}
"""
let dev = MTLCreateSystemDefaultDevice()!
let lib = try! dev.makeLibrary(source: src, options: nil)
let pso = try! dev.makeComputePipelineState(function: lib.makeFunction(name: "k")!)
let n = 1 << 20
let buf = dev.makeBuffer(length: 32, options: .storageModeShared)!
memset(buf.contents(), 0, 32)
let q = dev.makeCommandQueue()!
let cb = q.makeCommandBuffer()!
let enc = cb.makeComputeCommandEncoder()!
enc.setComputePipelineState(pso); enc.setBuffer(buf, offset: 0, index: 0)
enc.dispatchThreads(MTLSize(width: n, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
let p = buf.contents().bindMemory(to: Float.self, capacity: 8)
print("\(dev.name): expected \(n/8) per cell, got \((0..<8).map { p[$0] }), gpu ms \((cb.gpuEndTime - cb.gpuStartTime) * 1000)")

import Metal
let src = """
#include <metal_stdlib>
using namespace metal;
uint3 gpos [[thread_position_in_grid]];
uint3 lpos [[thread_position_in_threadgroup]];
uint3 gsize [[threads_per_grid]];
static inline uint helper() { return gpos.x * 10u + lpos.x; }
kernel void fill(device uint* out, device uint* out2) {
    out[gpos.x] = helper();
    out2[gpos.x] = gsize.x;
}
"""
let dev = MTLCreateSystemDefaultDevice()!
do {
    let lib = try dev.makeLibrary(source: src, options: nil)
    let pso = try dev.makeComputePipelineState(function: lib.makeFunction(name: "fill")!)
    let n = 1000
    let b1 = dev.makeBuffer(length: n*4, options: .storageModeShared)!
    let b2 = dev.makeBuffer(length: n*4, options: .storageModeShared)!
    let q = dev.makeCommandQueue()!
    let cb = q.makeCommandBuffer()!
    let enc = cb.makeComputeCommandEncoder()!
    enc.setComputePipelineState(pso)
    enc.setBuffer(b1, offset: 0, index: 0)
    enc.setBuffer(b2, offset: 0, index: 1)
    enc.dispatchThreads(MTLSize(width: n, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
    enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    let p = b1.contents().bindMemory(to: UInt32.self, capacity: n)
    let p2 = b2.contents().bindMemory(to: UInt32.self, capacity: n)
    var bad = 0
    for i in 0..<n { if p[i] != UInt32(i*10 + i%64) || p2[i] != UInt32(n) { bad += 1 } }
    print("device=\(dev.name) wrong=\(bad) sample=\(p[0]),\(p[65]),\(p[999]) gsize=\(p2[5])")
} catch { print("ERROR: \(error)") }

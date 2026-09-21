import Metal
// OpenCL C builds a vector with (float4) (a, b, c, d). MSL is C++: what does the same text do?
let src = """
#include <metal_stdlib>
using namespace metal;
kernel void k(device float4* out, constant float& a, uint g [[thread_position_in_grid]]) {
    out[0] = (float4) (a, a + 1, a + 2, a + 3);
    out[1] = float4(a, a + 1, a + 2, a + 3);
}
"""
let dev = MTLCreateSystemDefaultDevice()!
let lib = try! dev.makeLibrary(source: src, options: nil)
let pso = try! dev.makeComputePipelineState(function: lib.makeFunction(name: "k")!)
let buf = dev.makeBuffer(length: 32, options: .storageModeShared)!
var a: Float = 1
let q = dev.makeCommandQueue()!
let cb = q.makeCommandBuffer()!
let enc = cb.makeComputeCommandEncoder()!
enc.setComputePipelineState(pso); enc.setBuffer(buf, offset: 0, index: 0); enc.setBytes(&a, length: 4, index: 1)
enc.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
let p = buf.contents().bindMemory(to: Float.self, capacity: 8)
print("\(dev.name): OpenCL-style literal gives \((0..<4).map { p[$0] }), constructor gives \((4..<8).map { p[$0] })")

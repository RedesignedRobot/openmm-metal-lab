// How long does macOS let a compute kernel spin before it kills the command buffer, and what does the host see?
import Metal
import Foundation

let device = MTLCreateSystemDefaultDevice()!
let source = """
#include <metal_stdlib>
using namespace metal;
kernel void spin(device uint* data [[buffer(0)]], uint gid [[thread_position_in_grid]]) {
    uint x = data[1];
    for (uint outer = 0; outer < data[0]; outer++)
        for (uint i = 0; i < 0xffffffffu; i++) { x = x * 1664525u + 1013904223u + (x >> 7); }
    data[1] = x;
}
"""
let library = try! device.makeLibrary(source: source, options: nil)
let pipeline = try! device.makeComputePipelineState(function: library.makeFunction(name: "spin")!)
let buffer = device.makeBuffer(length: 16, options: .storageModeShared)!
memset(buffer.contents(), 0, 16)
buffer.contents().assumingMemoryBound(to: UInt32.self)[0] = 100000
let commandBuffer = device.makeCommandQueue()!.makeCommandBuffer()!
let encoder = commandBuffer.makeComputeCommandEncoder()!
encoder.setComputePipelineState(pipeline)
encoder.setBuffer(buffer, offset: 0, index: 0)
encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
encoder.endEncoding()
let done = DispatchSemaphore(value: 0)
commandBuffer.addCompletedHandler { _ in done.signal() }
let start = Date()
commandBuffer.commit()
let result = done.wait(timeout: .now() + 120)
let elapsed = Date().timeIntervalSince(start)
if result == .timedOut {
    print("\(device.name): still running after 120 s, status \(commandBuffer.status.rawValue)")
    exit(1)
}
print("\(device.name): ended after \(String(format: "%.1f", elapsed)) s, status \(commandBuffer.status.rawValue), error \(commandBuffer.error.map { "\($0)" } ?? "nil")")

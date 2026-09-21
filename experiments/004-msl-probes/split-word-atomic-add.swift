import Metal
// OpenMM's OpenCL prelude accumulates 64-bit fixed-point forces with two 32-bit atomic adds and a carry.
// This probe runs the same algorithm in MSL under heavy contention and compares with the exact sum.
let src = """
#include <metal_stdlib>
using namespace metal;
inline void atom_add(device ulong* p, ulong val) {
    device atomic_uint* word = (device atomic_uint*) p;
    uint lower = (uint) val;
    uint upper = (uint) (val >> 32);
    uint previous = atomic_fetch_add_explicit(&word[0], lower, memory_order_relaxed);
    upper += ((ulong) lower + (ulong) previous >= 0x100000000ul) ? 1u : 0u;
    if (upper != 0u)
        atomic_fetch_add_explicit(&word[1], upper, memory_order_relaxed);
}
kernel void k(device ulong* cells, uint g [[thread_position_in_grid]]) {
    // Values near 2^32 force a carry on almost every add. Negative fixed-point values are large ulongs.
    ulong value = 0xFFFFFF00ul + (ulong) g;
    if ((g & 1u) == 1u) value = (ulong) (-(long) (0x7FFFFFFFul + (ulong) g));
    atom_add(&cells[g % 8u], value);
}
"""
let dev = MTLCreateSystemDefaultDevice()!
let lib = try! dev.makeLibrary(source: src, options: nil)
let pso = try! dev.makeComputePipelineState(function: lib.makeFunction(name: "k")!)
let n = 1 << 22
let buf = dev.makeBuffer(length: 64, options: .storageModeShared)!
memset(buf.contents(), 0, 64)
let q = dev.makeCommandQueue()!
let cb = q.makeCommandBuffer()!
let enc = cb.makeComputeCommandEncoder()!
enc.setComputePipelineState(pso); enc.setBuffer(buf, offset: 0, index: 0)
enc.dispatchThreads(MTLSize(width: n, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
var expected = [UInt64](repeating: 0, count: 8)
for g in 0..<n {
    var value = UInt64(0xFFFFFF00) &+ UInt64(g)
    if g & 1 == 1 { value = UInt64(bitPattern: -Int64(0x7FFFFFFF + g)) }
    expected[g % 8] = expected[g % 8] &+ value
}
let p = buf.contents().bindMemory(to: UInt64.self, capacity: 8)
let wrong = (0..<8).filter { p[$0] != expected[$0] }.count
print("\(dev.name): \(n) contended split-word adds into 8 cells, wrong cells: \(wrong), gpu ms \((cb.gpuEndTime - cb.gpuStartTime) * 1000)")

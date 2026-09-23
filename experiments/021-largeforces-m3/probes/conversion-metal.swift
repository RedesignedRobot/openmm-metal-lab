// Hypothesis (b): what does an out-of-range float -> integer conversion return on this GPU?
// Same compile options as MetalContext.cpp (MSL 3.1, safe math); the inputs come from a buffer
// so the compiler cannot fold the conversions.
import Metal

let src = """
#include <metal_stdlib>
using namespace metal;
kernel void conv(device const float* in [[buffer(0)]], device long* fixedOut [[buffer(1)]],
                 device long* longOut [[buffer(2)]], device ulong* ulongOut [[buffer(3)]],
                 device int* intOut [[buffer(4)]], device uint* uintOut [[buffer(5)]],
                 uint g [[thread_position_in_grid]]) {
    float x = in[g];
    fixedOut[g] = (long) (x*0x100000000);   // realToFixedPoint in common.metal
    longOut[g] = (long) x;
    ulongOut[g] = (ulong) x;
    intOut[g] = (int) x;
    uintOut[g] = (uint) x;
}
"""

let inputs: [Float] = [
    0, 1, -1, 1.5, -1.5,
    Float(1 << 30), 2147483520, 2147483648, -2147483648, -2147483904, 4294967040, 4294967296,
    4.0e9, 1.0e10, -1.0e10, 4.611686e18, 9.2233715e18, 9.223372e18, -9.223372e18, -9.2233725e18,
    1.8446743e19, 3.0e19, -3.0e19, 1.0e20, -1.0e20, 1.0e26, -1.0e26, 3.4028235e38, -3.4028235e38,
    .infinity, -.infinity, .nan,
]

let dev = MTLCreateSystemDefaultDevice()!
let opts = MTLCompileOptions()
opts.languageVersion = .version3_1
opts.mathMode = CommandLine.arguments.contains("fast") ? .fast : .safe
let lib = try! dev.makeLibrary(source: src, options: opts)
let pso = try! dev.makeComputePipelineState(function: lib.makeFunction(name: "conv")!)
let n = inputs.count
let inBuf = dev.makeBuffer(bytes: inputs, length: 4 * n, options: .storageModeShared)!
let outs = [8, 8, 8, 4, 4].map { dev.makeBuffer(length: $0 * n, options: .storageModeShared)! }
let q = dev.makeCommandQueue()!
let cb = q.makeCommandBuffer()!
let enc = cb.makeComputeCommandEncoder()!
enc.setComputePipelineState(pso)
enc.setBuffer(inBuf, offset: 0, index: 0)
for (i, b) in outs.enumerated() { enc.setBuffer(b, offset: 0, index: i + 1) }
enc.dispatchThreads(MTLSize(width: n, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: n, height: 1, depth: 1))
enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()

let fixed = outs[0].contents().bindMemory(to: Int64.self, capacity: n)
let l = outs[1].contents().bindMemory(to: Int64.self, capacity: n)
let ul = outs[2].contents().bindMemory(to: UInt64.self, capacity: n)
let i32 = outs[3].contents().bindMemory(to: Int32.self, capacity: n)
let u32 = outs[4].contents().bindMemory(to: UInt32.self, capacity: n)
func hex64(_ v: UInt64) -> String { "0x" + String(format: "%016llx", v) }
func hex32(_ v: UInt32) -> String { "0x" + String(format: "%08x", v) }
print("device \(dev.name) mathMode \(opts.mathMode == .fast ? "fast" : "safe")")
print("input(float bits)      input            (long)(x*2^32)       (long)x              (ulong)x             (int)x      (uint)x")
for k in 0..<n {
    let x = inputs[k]
    print(String(format: "%@  %-15.8g  ", hex32(x.bitPattern), x) +
          "\(hex64(UInt64(bitPattern: fixed[k])))  \(hex64(UInt64(bitPattern: l[k])))  \(hex64(ul[k]))  \(hex32(UInt32(bitPattern: i32[k])))  \(hex32(u32[k]))")
}

// Candidate fix: saturate realToFixedPoint explicitly instead of relying on the conversion.
// Runs the current and the saturated conversion over random float bit patterns covering the whole
// exponent range and counts disagreements with a host reference that truncates toward zero and
// saturates to [INT64_MIN, INT64_MAX] (what the M2 and CUDA do). NaN inputs are reported separately.
import Metal

let src = """
#include <metal_stdlib>
using namespace metal;
inline long current(float x) {
    return (long) (x*0x100000000);
}
inline long saturated(float x) {
    float v = x*0x100000000;
    return v < -0x1p63f ? LONG_MIN : v >= 0x1p63f ? LONG_MAX : (long) v;
}
kernel void conv(device const float* in [[buffer(0)]], device long* cur [[buffer(1)]], device long* fix [[buffer(2)]],
                 uint g [[thread_position_in_grid]]) {
    cur[g] = current(in[g]);
    fix[g] = saturated(in[g]);
}
"""

func reference(_ x: Float) -> Int64 {
    let v = Double(x) * 4294967296.0   // exact: only the exponent changes
    if v >= 9223372036854775808.0 { return Int64.max }
    if v <= -9223372036854775808.0 { return Int64.min }
    return Int64(v)   // truncates toward zero
}

var inputs: [Float] = [.infinity, -.infinity, 0x1p31, -0x1p31, 0x1.fffffep30, -0x1.fffffep30, 0x1p30, 0, -0.0]
var rng = SystemRandomNumberGenerator()
while inputs.count < 1 << 20 {
    let x = Float(bitPattern: UInt32.random(in: 0...UInt32.max, using: &rng))
    if !x.isNaN { inputs.append(x) }
}
let nanIndex = inputs.count
inputs.append(.nan)
let n = inputs.count

let dev = MTLCreateSystemDefaultDevice()!
let opts = MTLCompileOptions()
opts.languageVersion = .version3_1
opts.mathMode = .safe
let lib = try! dev.makeLibrary(source: src, options: opts)
let pso = try! dev.makeComputePipelineState(function: lib.makeFunction(name: "conv")!)
let inBuf = dev.makeBuffer(bytes: inputs, length: 4 * n, options: .storageModeShared)!
let curBuf = dev.makeBuffer(length: 8 * n, options: .storageModeShared)!
let fixBuf = dev.makeBuffer(length: 8 * n, options: .storageModeShared)!
let q = dev.makeCommandQueue()!
let cb = q.makeCommandBuffer()!
let enc = cb.makeComputeCommandEncoder()!
enc.setComputePipelineState(pso)
enc.setBuffer(inBuf, offset: 0, index: 0); enc.setBuffer(curBuf, offset: 0, index: 1); enc.setBuffer(fixBuf, offset: 0, index: 2)
enc.dispatchThreads(MTLSize(width: n, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
let cur = curBuf.contents().bindMemory(to: Int64.self, capacity: n)
let fix = fixBuf.contents().bindMemory(to: Int64.self, capacity: n)

var curBad = 0, fixBad = 0, inRange = 0, inRangeCurBad = 0, inRangeFixBad = 0, firstBad = -1
for i in 0..<n where i != nanIndex {
    let ref = reference(inputs[i])
    let fits = abs(Double(inputs[i]) * 4294967296.0) < 9223372036854775808.0
    if fits { inRange += 1 }
    if cur[i] != ref { curBad += 1; if fits { inRangeCurBad += 1 }; if firstBad < 0 { firstBad = i } }
    if fix[i] != ref { fixBad += 1; if fits { inRangeFixBad += 1 } }
}
print("device \(dev.name), \(n - 1) non-NaN inputs (\(inRange) whose fixed-point value fits in 64 bits)")
print("current (long)(x*2^32):  \(curBad) disagree with saturating reference (\(inRangeCurBad) of them in range)")
print("saturated:               \(fixBad) disagree with saturating reference (\(inRangeFixBad) of them in range)")
if firstBad >= 0 {
    print(String(format: "first current disagreement: x=0x%08x (%g) got 0x%016llx want 0x%016llx", inputs[firstBad].bitPattern, inputs[firstBad], UInt64(bitPattern: cur[firstBad]), UInt64(bitPattern: reference(inputs[firstBad]))))
}
print(String(format: "NaN: current 0x%016llx, saturated 0x%016llx", UInt64(bitPattern: cur[nanIndex]), UInt64(bitPattern: fix[nanIndex])))

// Hypothesis (a): does atomic_fetch_add on atomic_float round to nearest even or toward zero?
// One thread per cell, so there is no contention and the only question is the rounding of a+b.
// Compares every result with host round-to-nearest-even and round-toward-zero.
import Metal

let src = """
#include <metal_stdlib>
using namespace metal;
kernel void add(device atomic_float* cell [[buffer(0)]], device const float* b [[buffer(1)]],
                uint g [[thread_position_in_grid]]) {
    atomic_fetch_add_explicit(&cell[g], b[g], memory_order_relaxed);
}
kernel void plainAdd(device float* cell [[buffer(0)]], device const float* b [[buffer(1)]],
                     uint g [[thread_position_in_grid]]) {
    cell[g] = cell[g] + b[g];
}
"""

func rtz(_ a: Float, _ b: Float) -> Float {
    // Exponent gaps stay under 29 bits below, so the double sum is exact.
    let exact = Double(a) + Double(b)
    var r = Float(exact)
    if abs(Double(r)) > abs(exact) { r = r.nextDown.magnitude < r.magnitude ? r.nextDown : r.nextUp }
    return r
}

var a: [Float] = [], b: [Float] = []
let ulp: Float = 1.0 / 8388608.0   // 2^-23
let hand: [(Float, Float)] = [
    (1, ulp / 2), (1, 3 * ulp / 2), (1 + ulp, ulp / 2), (1, -ulp / 4), (1, -ulp / 2 * 0.75),
    (-1, -3 * ulp / 2), (-1 - ulp, -ulp / 2), (1e30, 1.2345e22), (-1e30, 7.0e21), (16777216, 1), (16777217 - 1, 3),
]
for (x, y) in hand { a.append(x); b.append(y) }
var rng = SystemRandomNumberGenerator()
while a.count < 1 << 20 {
    let x = Float(Double.random(in: 1..<2, using: &rng)) * Float(sign: Bool.random(using: &rng) ? .minus : .plus, exponent: Int.random(in: -20...20, using: &rng), significand: 1)
    let y = Float(Double.random(in: 1..<2, using: &rng)) * Float(sign: Bool.random(using: &rng) ? .minus : .plus, exponent: x.exponent - Int.random(in: 0...28, using: &rng), significand: 1)
    a.append(x); b.append(y)
}
let n = a.count
let dev = MTLCreateSystemDefaultDevice()!
let opts = MTLCompileOptions()
opts.languageVersion = .version3_1
opts.mathMode = .safe
let lib = try! dev.makeLibrary(source: src, options: opts)
let q = dev.makeCommandQueue()!
func run(_ name: String) -> [Float] {
    let pso = try! dev.makeComputePipelineState(function: lib.makeFunction(name: name)!)
    let cell = dev.makeBuffer(bytes: a, length: 4 * n, options: .storageModeShared)!
    let bb = dev.makeBuffer(bytes: b, length: 4 * n, options: .storageModeShared)!
    let cb = q.makeCommandBuffer()!
    let enc = cb.makeComputeCommandEncoder()!
    enc.setComputePipelineState(pso); enc.setBuffer(cell, offset: 0, index: 0); enc.setBuffer(bb, offset: 0, index: 1)
    enc.dispatchThreads(MTLSize(width: n, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
    enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    return Array(UnsafeBufferPointer(start: cell.contents().bindMemory(to: Float.self, capacity: n), count: n))
}
print("device \(dev.name), \(n) additions, one thread per cell")
for name in ["add", "plainAdd"] {
    let got = run(name)
    var matchRNE = 0, matchRTZ = 0, inexact = 0, inexactRNE = 0, inexactRTZ = 0, neither = 0
    for i in 0..<n {
        let rne = a[i] + b[i], z = rtz(a[i], b[i])
        if got[i].bitPattern == rne.bitPattern { matchRNE += 1 }
        if got[i].bitPattern == z.bitPattern { matchRTZ += 1 }
        if got[i].bitPattern != rne.bitPattern && got[i].bitPattern != z.bitPattern { neither += 1 }
        if rne != z {
            inexact += 1
            if got[i].bitPattern == rne.bitPattern { inexactRNE += 1 }
            if got[i].bitPattern == z.bitPattern { inexactRTZ += 1 }
        }
    }
    print("\(name): matches RNE \(matchRNE)/\(n), RTZ \(matchRTZ)/\(n), neither \(neither); on the \(inexact) cases where RNE != RTZ: RNE \(inexactRNE), RTZ \(inexactRTZ)")
    for i in 0..<hand.count {
        print(String(format: "  %@ a=0x%08x b=0x%08x got=0x%08x rne=0x%08x rtz=0x%08x", name, a[i].bitPattern, b[i].bitPattern, got[i].bitPattern, (a[i] + b[i]).bitPattern, rtz(a[i], b[i]).bitPattern))
    }
}

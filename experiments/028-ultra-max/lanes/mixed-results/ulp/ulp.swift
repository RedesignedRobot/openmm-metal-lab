import Metal
import Foundation

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

let n = 1 << 22
let names = ["x/y", "1/precise::sqrt(x)", "precise::sqrt(x)", "exp(y)", "erfc_oc(y)", "two_sum err (pragma safe)",
             "two_sum err (no pragma)", "fast::divide(1,x)", "precise::divide(x,y)", "1/x",
             "A&S erfc (PME direct), vs the same formula in double"]
let outs = names.count
let dev = MTLCreateSystemDefaultDevice()!
let queue = dev.makeCommandQueue()!
let src = try! String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)

var g = SplitMix64(state: 12345)
var a = [Float](repeating: 0, count: n)
var b = [Float](repeating: 0, count: n)
for i in 0..<n {
    a[i] = Float(pow(10.0, Double.random(in: -4...4, using: &g)))
    b[i] = Float.random(in: -10...10, using: &g)
}

func run(_ mode: MTLMathMode) -> [Float] {
    let opts = MTLCompileOptions()
    opts.languageVersion = .version3_2
    opts.mathMode = mode
    opts.mathFloatingPointFunctions = .precise
    let lib = try! dev.makeLibrary(source: src, options: opts)
    let pso = try! dev.makeComputePipelineState(function: lib.makeFunction(name: "ops")!)
    let ba = dev.makeBuffer(bytes: a, length: n*4, options: .storageModeShared)!
    let bb = dev.makeBuffer(bytes: b, length: n*4, options: .storageModeShared)!
    let bo = dev.makeBuffer(length: n*4*outs, options: .storageModeShared)!
    var nn = UInt32(n)
    let cb = queue.makeCommandBuffer()!
    let enc = cb.makeComputeCommandEncoder()!
    enc.setComputePipelineState(pso)
    enc.setBuffer(ba, offset: 0, index: 0)
    enc.setBuffer(bb, offset: 0, index: 1)
    enc.setBuffer(bo, offset: 0, index: 2)
    enc.setBytes(&nn, length: 4, index: 3)
    enc.dispatchThreads(MTLSize(width: n, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
    enc.endEncoding()
    cb.commit()
    cb.waitUntilCompleted()
    let p = bo.contents().bindMemory(to: Float.self, capacity: n*outs)
    return Array(UnsafeBufferPointer(start: p, count: n*outs))
}

func ordered(_ f: Float) -> Int64 {
    let u = Int64(f.bitPattern)
    return u & 0x80000000 != 0 ? -(u & 0x7fffffff) : u
}

func ulps(_ x: Float, _ y: Float) -> Int64 {
    if x.isNaN && y.isNaN { return 0 }
    if x.isNaN || y.isNaN { return Int64.max }
    return abs(ordered(x) - ordered(y))
}

func reference(_ k: Int, _ x: Float, _ y: Float) -> Float? {
    let dx = Double(x), dy = Double(y)
    switch k {
    case 0, 8: return Float(dx/dy)
    case 1: return Float(1/dx.squareRoot())
    case 2: return Float(dx.squareRoot())
    case 3: return Float(exp(dy))
    case 5, 6: return Float(dx+dy-Double(x+y))
    case 7, 9: return Float(1/dx)
    case 10:
        let r = Double(abs(y)*Float(0.35))
        let t = 1/(1+0.3275911*r)
        return Float((0.254829592+(-0.284496736+(1.421413741+(-1.453152027+1.061405429*t)*t)*t)*t)*t*exp(-r*r))
    default: return nil
    }
}

let safe = run(.safe)
let relaxed = run(.relaxed)
print("op | outputs that differ safe vs relaxed | max ulp safe vs relaxed | max ulp safe vs exact | max ulp relaxed vs exact")
for k in 0..<outs {
    var differ = 0
    var maxDiff: Int64 = 0, maxSafe: Int64 = 0, maxRelaxed: Int64 = 0
    for i in 0..<n {
        let s = safe[k*n+i], r = relaxed[k*n+i]
        let d = ulps(s, r)
        if d != 0 { differ += 1 }
        maxDiff = max(maxDiff, d)
        guard let ref = reference(k, a[i], b[i]) else { continue }
        maxSafe = max(maxSafe, ulps(s, ref))
        maxRelaxed = max(maxRelaxed, ulps(r, ref))
    }
    let hasRef = reference(k, a[0], b[0]) != nil
    print("\(names[k]) | \(differ) | \(maxDiff) | \(hasRef ? String(maxSafe) : "-") | \(hasRef ? String(maxRelaxed) : "-")")
}

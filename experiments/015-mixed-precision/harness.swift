// Experiment 015: df64 mixed precision on an Apple GPU.
// usage: harness [accuracy|convert|census|timing|all] [--kernels DIR]
// Every section prints markdown tables to stdout; run.sh keeps the log.

import Foundation
import Metal

// MARK: - Setup

let args = CommandLine.arguments
let section = args.count > 1 ? args[1] : "all"
let verbose = args.contains("--verbose")
let here = URL(fileURLWithPath: args[0]).deletingLastPathComponent().path
let kernelsDir: String = {
    if let i = args.firstIndex(of: "--kernels"), i + 1 < args.count { return args[i + 1] }
    return "\(here)/openmm-kernels"
}()

let device = MTLCreateSystemDefaultDevice()!
let queue = device.makeCommandQueue()!

func readFile(_ path: String) -> String {
    guard let s = try? String(contentsOfFile: path, encoding: .utf8) else {
        fputs("cannot read \(path)\n", stderr)
        exit(1)
    }
    return s
}

let df64Source = readFile("\(here)/df64.metal")
let convertSource = readFile("\(here)/df64_convert.metal")
let preludeSource = readFile("\(here)/prelude.metal")
let stdHeader = "#include <metal_stdlib>\nusing namespace metal;\n"

func compileOptions(_ mode: MTLMathMode) -> MTLCompileOptions {
    let o = MTLCompileOptions()
    o.languageVersion = .version3_1
    o.mathMode = mode
    return o
}

func makeLibrary(_ source: String, _ mode: MTLMathMode = .safe) -> MTLLibrary {
    do {
        return try device.makeLibrary(source: source, options: compileOptions(mode))
    } catch {
        fputs("compile failed: \(error)\n", stderr)
        exit(1)
    }
}

func makePipeline(_ lib: MTLLibrary, _ name: String) -> MTLComputePipelineState {
    guard let f = lib.makeFunction(name: name), let p = try? device.makeComputePipelineState(function: f) else {
        fputs("no pipeline for \(name)\n", stderr)
        exit(1)
    }
    return p
}

func makeBuffer<T>(_ values: [T]) -> MTLBuffer {
    values.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: max($0.count, 16), options: .storageModeShared)! }
}

func readBuffer<T>(_ buffer: MTLBuffer, _ count: Int, as: T.Type) -> [T] {
    let p = buffer.contents().bindMemory(to: T.self, capacity: count)
    return Array(UnsafeBufferPointer(start: p, count: count))
}

func commit(_ cb: MTLCommandBuffer) {
    cb.commit()
    cb.waitUntilCompleted()
    if cb.status != .completed {
        fputs("command buffer failed: \(String(describing: cb.error))\n", stderr)
        exit(2)
    }
}

// One dispatch of a 1-D kernel over `threads` threads with the given buffers bound in order.
func dispatch(_ pso: MTLComputePipelineState, _ buffers: [MTLBuffer], _ threads: Int, bytes: [(Int, [UInt32])] = []) {
    let cb = queue.makeCommandBuffer()!
    let enc = cb.makeComputeCommandEncoder()!
    enc.setComputePipelineState(pso)
    for (i, b) in buffers.enumerated() { enc.setBuffer(b, offset: 0, index: i) }
    for (index, words) in bytes { words.withUnsafeBytes { enc.setBytes($0.baseAddress!, length: $0.count, index: index) } }
    enc.dispatchThreads(MTLSize(width: threads, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
    enc.endEncoding()
    commit(cb)
}

struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func uniform() -> Double { Double(next() >> 11) * 0x1p-53 }
    mutating func uniform(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * uniform() }
    // Log-uniform magnitude in [lo, hi], optional random sign.
    mutating func logUniform(_ lo: Double, _ hi: Double, signed: Bool = true) -> Double {
        let m = exp(uniform(log(lo), log(hi)))
        return signed && next() & 1 == 1 ? -m : m
    }
}

// CPU reference split of a double into a double-word pair (hi = RN(hi + lo)), the rule df64_from_ieee
// implements: hi = RN(d), lo = RN(d - hi), except that a lo of half an ulp of an odd hi, which would make
// hi + lo round away from hi, moves one float towards zero. d - hi is exact in double.
func split(_ d: Double) -> (Float, Float) {
    let hi = Float(d)
    if !d.isFinite || !hi.isFinite { return (hi, 0) }
    let lo = Float(d - Double(hi))
    if isDoubleWord(hi, lo) { return (hi, lo) }
    return (hi, lo > 0 ? lo.nextDown : lo.nextUp)
}

// hi = RN(hi + lo). The double sum is exact whenever lo is within a few ulps of a float tie of hi, so
// rounding it to float decides the question.
func isDoubleWord(_ hi: Float, _ lo: Float) -> Bool {
    if !hi.isFinite { return lo == 0 }
    return Float(Double(hi) + Double(lo)) == hi
}

func value(_ hi: Float, _ lo: Float) -> Double { Double(hi) + Double(lo) }

func median(_ v: [Double]) -> Double {
    let s = v.sorted()
    return s.isEmpty ? .nan : s[s.count / 2]
}

func percentile(_ sorted: [Double], _ p: Double) -> Double {
    sorted.isEmpty ? .nan : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
}

func sysctlString(_ name: String) -> String {
    var size = 0
    sysctlbyname(name, nil, &size, nil, 0)
    var buf = [CChar](repeating: 0, count: size)
    sysctlbyname(name, &buf, &size, nil, 0)
    return String(cString: buf)
}

print("# Experiment 015 run")
print("")
print("Chip: \(sysctlString("machdep.cpu.brand_string")) (\(device.name)), macOS \(ProcessInfo.processInfo.operatingSystemVersionString), \(ISO8601DateFormatter().string(from: Date()))")
print("Compile: MSL 3.1, mathMode = .safe unless a table says otherwise. Command: \(args.joined(separator: " "))")
print("")

// MARK: - 3a. Accuracy

let accuracySource = stdHeader + df64Source + """

kernel void binary(device const float2* a [[buffer(0)]], device const float2* b [[buffer(1)]],
        device const long* n [[buffer(2)]], device float2* out [[buffer(3)]], constant uint& op [[buffer(4)]],
        uint i [[thread_position_in_grid]]) {
    df64 x(a[i].x, a[i].y);
    df64 y(b[i].x, b[i].y);
    df64 r;
    switch (op) {
        case 0: r = x + y; break;
        case 1: r = x - y; break;
        case 2: r = x * y; break;
        case 3: r = x / y; break;
        case 4: r = x + y.hi; break;
        case 5: r = x * y.hi; break;
        case 6: r = x / y.hi; break;
        case 7: r = sqrt(x); break;
        case 8: r = exp(x); break;
        case 9: r = log(x); break;
        case 10: r = df64(n[i]); break;
        case 11: r = x * n[i]; break;
        case 12: r = fabs(x); break;
        case 13: r = max(x, y); break;
    }
    out[i] = float2(r.hi, r.lo);
}

// Operands decoded on the GPU from IEEE doubles, as every IEEE-storage load does. `stable` checks that
// adding zero or multiplying by one returns the same pair, which holds only for double-word pairs.
kernel void compare(device const uint2* a [[buffer(0)]], device const uint2* b [[buffer(1)]],
        device uint4* out [[buffer(2)]], device float4* pairs [[buffer(3)]], uint i [[thread_position_in_grid]]) {
    df64 x = df64_from_ieee(a[i]);
    df64 y = df64_from_ieee(b[i]);
    uint bits = (x < y) | ((x <= y) << 1) | ((x == y) << 2) | ((x > y) << 3) | ((x >= y) << 4) | ((x != y) << 5);
    df64 z = x + df64(0.0f);
    bool stable = x == z && !(x < z) && !(z < x) && x == x + 0.0f && x == x * 1.0f && x == x * df64(1.0f);
    out[i] = uint4(bits, as_type<uint>((float) x), stable ? 1u : 0u, 0u);
    pairs[i] = float4(x.hi, x.lo, y.hi, y.lo);
}

// The float primitives df64 relies on: correct rounding of sqrt and division.
kernel void primitives(device const float2* a [[buffer(0)]], device float4* out [[buffer(1)]], uint i [[thread_position_in_grid]]) {
    float x = a[i].x, y = a[i].y;
    out[i] = float4(sqrt(x), x / y, precise::sqrt(x), precise::divide(x, y));
}

// Subnormal handling: 2^-140 * 1, 2^-70 * 2^-70, and 2^-140 != 0.
kernel void subnormals(device const float* in [[buffer(0)]], device float* out [[buffer(1)]]) {
    out[0] = in[0] * in[1];
    out[1] = in[2] * in[2];
    out[2] = in[0] != 0.0f ? 1.0f : 0.0f;
}

// Error-free transformation canary: exact error of 1 + 2^-30 and of (1 + 2^-12)^2.
kernel void canary(device float* out [[buffer(0)]], device const float* in [[buffer(1)]]) {
    out[0] = df64_two_sum(in[0], in[1]).y;
    out[1] = df64_two_prod(in[2], in[2]).y;
}
"""

struct AccuracyCase {
    let name: String
    let op: UInt32
    let domain: String
    let bound: String
    let make: (inout SplitMix64) -> (Double, Double, Int64)
    let reference: (Double, Double, Int64) -> Double
}

let unit48 = 0x1p-48
let flagUnits = 16.0 // 2^-44 in units of 2^-48

func gpuBinary(_ pso: MTLComputePipelineState, op: UInt32, a: [SIMD2<Float>], b: [SIMD2<Float>], n: [Int64]) -> [SIMD2<Float>] {
    let count = a.count
    let out = device.makeBuffer(length: count * 8, options: .storageModeShared)!
    let cb = queue.makeCommandBuffer()!
    let enc = cb.makeComputeCommandEncoder()!
    enc.setComputePipelineState(pso)
    enc.setBuffer(makeBuffer(a), offset: 0, index: 0)
    enc.setBuffer(makeBuffer(b), offset: 0, index: 1)
    enc.setBuffer(makeBuffer(n), offset: 0, index: 2)
    enc.setBuffer(out, offset: 0, index: 3)
    var o = op
    enc.setBytes(&o, length: 4, index: 4)
    enc.dispatchThreads(MTLSize(width: count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
    enc.endEncoding()
    commit(cb)
    return readBuffer(out, count, as: SIMD2<Float>.self)
}

struct ErrorStats {
    let median: Double
    let p999: Double
    let max: Double
    let flagged: Int
    let nonFinite: Int
}

func runCase(_ c: AccuracyCase, _ pso: MTLComputePipelineState, samples: Int, seed: UInt64) -> ErrorStats {
    var rng = SplitMix64(state: seed)
    var a = [SIMD2<Float>](), b = [SIMD2<Float>](), n = [Int64](), refs = [Double]()
    a.reserveCapacity(samples); b.reserveCapacity(samples); n.reserveCapacity(samples); refs.reserveCapacity(samples)
    for _ in 0..<samples {
        let (x, y, k) = c.make(&rng)
        let (xh, xl) = split(x), (yh, yl) = split(y)
        a.append(SIMD2(xh, xl)); b.append(SIMD2(yh, yl)); n.append(k)
        refs.append(c.reference(value(xh, xl), value(yh, yl), k))
    }
    let out = gpuBinary(pso, op: c.op, a: a, b: b, n: n)
    var errors = [Double](repeating: 0, count: samples)
    var nonFinite = 0
    for i in 0..<samples {
        let got = value(out[i].x, out[i].y)
        if !got.isFinite { nonFinite += 1; errors[i] = .infinity; continue }
        let ref = refs[i]
        errors[i] = ref == 0 ? abs(got) / unit48 : abs(got - ref) / abs(ref) / unit48
    }
    let sorted = errors.sorted()
    return ErrorStats(median: sorted[samples / 2], p999: percentile(sorted, 0.999), max: sorted.last!,
                      flagged: errors.filter { $0 > flagUnits }.count, nonFinite: nonFinite)
}

// MD magnitudes: positions 1e-3..1e3 nm, velocities 1e-4..1e1 nm/ps, energies to 1e7 kJ/mol.
let accuracyCases: [AccuracyCase] = [
    AccuracyCase(name: "df64 + df64", op: 0, domain: "a, b in +-[1e-4, 1e7]", bound: "3u^2 + 13u^3 = 3 (JMP Thm 3.1)",
                 make: { r in (r.logUniform(1e-4, 1e7), r.logUniform(1e-4, 1e7), 0) }, reference: { x, y, _ in x + y }),
    AccuracyCase(name: "df64 + df64 (position + step)", op: 0, domain: "a in +-[1e-3, 1e3], b in +-[1e-9, 1e-2]", bound: "3",
                 make: { r in (r.logUniform(1e-3, 1e3), r.logUniform(1e-9, 1e-2), 0) }, reference: { x, y, _ in x + y }),
    AccuracyCase(name: "df64 + df64 (cancellation)", op: 0, domain: "b = -a(1+d), d in +-[2^-40, 2^-8]", bound: "3",
                 make: { r in let x = r.logUniform(1e-3, 1e7); return (x, -x * (1 + r.logUniform(0x1p-40, 0x1p-8)), 0) },
                 reference: { x, y, _ in x + y }),
    AccuracyCase(name: "df64 - df64", op: 1, domain: "a, b in +-[1e-4, 1e7]", bound: "3",
                 make: { r in (r.logUniform(1e-4, 1e7), r.logUniform(1e-4, 1e7), 0) }, reference: { x, y, _ in x - y }),
    AccuracyCase(name: "df64 * df64", op: 2, domain: "a, b in +-[1e-4, 1e7]", bound: "4u^2 = 4 (MR Thm 2.8)",
                 make: { r in (r.logUniform(1e-4, 1e7), r.logUniform(1e-4, 1e7), 0) }, reference: { x, y, _ in x * y }),
    AccuracyCase(name: "df64 / df64", op: 3, domain: "a, b in +-[1e-4, 1e7]", bound: "15u^2 + 56u^3 = 15 (JMP Thm 7.1)",
                 make: { r in (r.logUniform(1e-4, 1e7), r.logUniform(1e-4, 1e7), 0) }, reference: { x, y, _ in x / y }),
    AccuracyCase(name: "df64 + float", op: 4, domain: "a in +-[1e-4, 1e7], b float in +-[1e-4, 1e7]", bound: "2u^2 = 2 (JMP Thm 2.2)",
                 make: { r in (r.logUniform(1e-4, 1e7), Double(Float(r.logUniform(1e-4, 1e7))), 0) }, reference: { x, y, _ in x + y }),
    AccuracyCase(name: "df64 * float", op: 5, domain: "a in +-[1e-4, 1e7], b float in +-[1e-4, 1e7]", bound: "2u^2 = 2 (JMP Thm 4.3)",
                 make: { r in (r.logUniform(1e-4, 1e7), Double(Float(r.logUniform(1e-4, 1e7))), 0) }, reference: { x, y, _ in x * y }),
    AccuracyCase(name: "df64 / float", op: 6, domain: "a in +-[1e-4, 1e7], b float in +-[1e-4, 1e7]", bound: "3u^2 = 3 (JMP Thm 6.2)",
                 make: { r in (r.logUniform(1e-4, 1e7), Double(Float(r.logUniform(1e-4, 1e7))), 0) }, reference: { x, y, _ in x / y }),
    AccuracyCase(name: "sqrt(df64)", op: 7, domain: "a in [1e-6, 1e7]", bound: "25/8 u^2 = 3.1",
                 make: { r in (r.logUniform(1e-6, 1e7, signed: false), 0, 0) }, reference: { x, _, _ in x.squareRoot() }),
    AccuracyCase(name: "exp(df64)", op: 8, domain: "a in [-60, 60]", bound: "none proven",
                 make: { r in (r.uniform(-60, 60), 0, 0) }, reference: { x, _, _ in Foundation.exp(x) }),
    AccuracyCase(name: "exp(df64), Langevin scale", op: 8, domain: "a in [-0.1, 0]", bound: "none proven",
                 make: { r in (r.uniform(-0.1, 0), 0, 0) }, reference: { x, _, _ in Foundation.exp(x) }),
    AccuracyCase(name: "log(df64)", op: 9, domain: "a in [1e-6, 1e7]", bound: "none proven",
                 make: { r in (r.logUniform(1e-6, 1e7, signed: false), 0, 0) }, reference: { x, _, _ in Foundation.log(x) }),
    AccuracyCase(name: "log(df64) near 1", op: 9, domain: "a = 1 + d, d in +-[1e-9, 0.5]", bound: "none proven",
                 make: { r in (1 + r.logUniform(1e-9, 0.5), 0, 0) }, reference: { x, _, _ in Foundation.log(x) }),
    AccuracyCase(name: "df64(long), fixed-point force", op: 10, domain: "n in +-[1, 2^62]", bound: "1 rounding of lo",
                 make: { r in (0, 0, Int64(r.logUniform(1, 0x1p62))) }, reference: { _, _, k in Double(k) }),
    AccuracyCase(name: "df64 * long, force scale", op: 11, domain: "a = dt/2^32, dt in [1e-4, 1e-2]; n in +-[1, 2^50]", bound: "4 + conversion",
                 make: { r in (r.logUniform(1e-4, 1e-2, signed: false) / 0x1p32, 0, Int64(r.logUniform(1, 0x1p50))) },
                 reference: { x, _, k in x * Double(k) }),
]

func runAccuracy() {
    print("## 3a. Accuracy of df64 operations against CPU double")
    print("")
    let samples = 1 << 20
    let lib = makeLibrary(accuracySource)
    let pso = makePipeline(lib, "binary")
    print("\(samples) random inputs per row, inputs are double-word pairs split from doubles by the decode rule, reference is the same op in CPU double on the exact pair values (itself within 2^-53 = 0.03 units).")
    print("Error = |gpu - ref| / |ref| in units of 2^-48. Flag threshold 2^-44 = 16 units. Proven bound in the same units (u = 2^-24, u^2 = 1 unit): JMP = Joldes, Muller, Popescu, ACM TOMS 44(2) 2017; MR = Muller, Rideau, ACM TOMS 48(1) 2022; sqrt: Lefevre et al., ACM TOMS 2023.")
    print("")
    print("| Operation | Inputs | Median | 99.9th pct | Max | Proven bound | > 2^-44 | Non-finite |")
    print("| --- | --- | ---: | ---: | ---: | --- | ---: | ---: |")
    for (i, c) in accuracyCases.enumerated() {
        let s = runCase(c, pso, samples: samples, seed: 0x15_0000 + UInt64(i))
        print("| \(c.name) | \(c.domain) | \(String(format: "%.3f", s.median)) | \(String(format: "%.3f", s.p999)) | \(String(format: "%.3f", s.max)) | \(c.bound) | \(s.flagged) | \(s.nonFinite) |")
    }
    print("")

    // Comparisons, narrowing to float and double-word form, on operands decoded on the GPU. Half the
    // doubles lie within 32 double ulps of a float tie of an odd hi (where RN(d - hi) can round up to
    // the tie); y is the same double, a neighbouring double, a neighbouring float, or unrelated.
    var rng = SplitMix64(state: 0x15_1000)
    var a = [UInt64](), b = [UInt64]()
    for k in 0..<samples {
        var x = rng.logUniform(1e-4, 1e7)
        if k % 2 == 0 {
            var h = Float(x)
            if h.bitPattern & 1 == 0 { h = h.nextUp }
            let half = Double(h.ulp) / 2, doubleUlp = Double(h.ulp) * 0x1p-29
            let side: Double = rng.next() & 1 == 1 ? 1 : -1
            x = Double(h) + side * (half - Double(Int(rng.next() % 33) - 1) * doubleUlp)
        }
        var y = x
        switch rng.next() % 6 {
        case 0: break
        case 1: y = x.nextUp
        case 2: y = x.nextDown
        case 3: y = Double(Float(x).nextUp)
        case 4: y = Double(Float(x).nextDown)
        default: y = rng.logUniform(1e-4, 1e7)
        }
        a.append(x.bitPattern); b.append(y.bitPattern)
    }
    let out = device.makeBuffer(length: samples * 16, options: .storageModeShared)!
    let pairOut = device.makeBuffer(length: samples * 16, options: .storageModeShared)!
    dispatch(makePipeline(lib, "compare"), [makeBuffer(a), makeBuffer(b), out, pairOut], samples)
    let got = readBuffer(out, samples, as: SIMD4<UInt32>.self)
    let pairs = readBuffer(pairOut, samples, as: SIMD4<Float>.self)
    var compareMismatch = 0, floatMismatch = 0, notDoubleWord = 0, unstable = 0, splitMismatch = 0
    for i in 0..<samples {
        let p = pairs[i]
        // Sign of x - y without rounding away a one-ulp difference in lo: both partial differences are
        // exact in double here, and rounding their sum never changes its sign.
        let diff = (Double(p.x) - Double(p.z)) + (Double(p.y) - Double(p.w))
        let want = UInt32(diff < 0 ? 1 : 0) | UInt32(diff <= 0 ? 2 : 0) | UInt32(diff == 0 ? 4 : 0) | UInt32(diff > 0 ? 8 : 0) | UInt32(diff >= 0 ? 16 : 0) | UInt32(diff != 0 ? 32 : 0)
        let d = Double(bitPattern: a[i])
        if got[i].x != want { compareMismatch += 1 }
        if got[i].y != Float(d).bitPattern { floatMismatch += 1 }
        if !isDoubleWord(p.x, p.y) || !isDoubleWord(p.z, p.w) { notDoubleWord += 1 }
        if got[i].z != 1 { unstable += 1 }
        let (sh, sl) = split(d)
        if sh.bitPattern != p.x.bitPattern || sl.bitPattern != p.y.bitPattern { splitMismatch += 1 }
    }
    print("Operands decoded on the GPU (df64_from_ieee) from \(samples) doubles in +-[1e-4, 1e7], half of them within 32 double ulps of a float tie of an odd hi; the second operand is the same double, a neighbouring double or float, or unrelated:")
    print("")
    print("- Decoded pairs that are not double-word numbers (hi != RN(hi + lo)): \(notDoubleWord). Decoded pairs that differ from the CPU split: \(splitMismatch).")
    print("- Comparisons (<, <=, ==, >, >=, !=) that disagree with exact comparison of the decoded values: \(compareMismatch).")
    print("- `(float) x` (the implicit `(real) mixed`) differing from RN(d) of the source double, bit for bit: \(floatMismatch).")
    print("- Pairs where x + 0, x + 0.0f, x * 1.0f or x * df64(1) is not the same pair: \(unstable).")
    print("")

    // Float primitives under safe math.
    var prng = SplitMix64(state: 0x15_1800)
    let primitiveCount = 1 << 22
    let operands = (0..<primitiveCount).map { _ in SIMD2(Float(prng.logUniform(1e-10, 1e10, signed: false)), Float(prng.logUniform(1e-10, 1e10, signed: false))) }
    let primitiveOut = device.makeBuffer(length: primitiveCount * 16, options: .storageModeShared)!
    dispatch(makePipeline(lib, "primitives"), [makeBuffer(operands), primitiveOut], primitiveCount)
    let primitive = readBuffer(primitiveOut, primitiveCount, as: SIMD4<Float>.self)
    var notCR = [0, 0, 0, 0]
    for i in 0..<primitiveCount {
        let x = operands[i].x, y = operands[i].y
        let want = [x.squareRoot(), x / y, x.squareRoot(), x / y]
        for j in 0..<4 where primitive[i][j].bitPattern != want[j].bitPattern { notCR[j] += 1 }
    }
    let subnormalOut = device.makeBuffer(length: 12, options: .storageModeShared)!
    dispatch(makePipeline(lib, "subnormals"), [makeBuffer([Float(0x1p-140), 1, Float(0x1p-70)]), subnormalOut], 1)
    let sub = readBuffer(subnormalOut, 3, as: Float.self)
    print("### Float primitives under safe math")
    print("")
    print("Results not correctly rounded, of \(primitiveCount) random operands in [1e-10, 1e10]: sqrt \(notCR[0]), x / y \(notCR[1]), precise::sqrt \(notCR[2]), precise::divide \(notCR[3]). df64 uses precise::sqrt and `/`.")
    print("Subnormals: 2^-140 * 1 = \(sub[0]), 2^-70 * 2^-70 = \(sub[1]) (exact: \(Float(0x1p-140))), (2^-140 != 0) = \(sub[2] == 1). Zero results mean flush to zero.")
    print("")

    // Math modes: the same kernel compiled with relaxed and fast math.
    print("### Math mode check")
    print("")
    print("| mathMode | two_sum(1, 2^-30) error term | two_prod(1+2^-12, same) error term | df64 + df64 max | df64 * df64 max | df64 / df64 max | sqrt max |")
    print("| --- | --- | --- | ---: | ---: | ---: | ---: |")
    for (label, mode) in [("safe", MTLMathMode.safe), ("relaxed", .relaxed), ("fast", .fast)] {
        let l = makeLibrary(accuracySource, mode)
        let p = makePipeline(l, "binary")
        let canaryOut = device.makeBuffer(length: 8, options: .storageModeShared)!
        dispatch(makePipeline(l, "canary"), [canaryOut, makeBuffer([Float(1), Float(0x1p-30), Float(1 + 0x1p-12)])], 1)
        let c = readBuffer(canaryOut, 2, as: Float.self)
        let picks = [0, 4, 5, 9].map { runCase(accuracyCases[$0], p, samples: 1 << 16, seed: 0x15_2000 + UInt64($0)).max }
        print("| \(label) | \(c[0]) (exact: \(Float(0x1p-30))) | \(c[1]) (exact: \(Float(0x1p-24))) | \(picks.map { String(format: "%.3g", $0) }.joined(separator: " | ")) |")
    }
    print("")
}

// MARK: - 3b. Conversion IEEE double <-> df64

func decodeReference(_ d: Double) -> (Float, Float) {
    if d.isNaN { return (d.sign == .minus ? -Float.nan : Float.nan, 0) }
    return split(d)
}

func encodeReference(_ hi: Float, _ lo: Float) -> Double {
    if hi.isNaN { return hi.sign == .minus ? -Double.nan : Double.nan }
    if hi.isInfinite || lo == 0 { return Double(hi) }
    return Double(hi) + Double(lo)
}

func sameFloat(_ a: Float, _ b: Float) -> Bool { a.isNaN ? (b.isNaN && a.sign == b.sign) : a.bitPattern == b.bitPattern }
func sameDouble(_ a: Double, _ b: Double) -> Bool { a.isNaN ? (b.isNaN && a.sign == b.sign) : a.bitPattern == b.bitPattern }

func convertInPlace(_ pso: MTLComputePipelineState, _ words: [UInt64]) -> [UInt64] {
    let buf = makeBuffer(words)
    dispatch(pso, [buf], words.count, bytes: [(1, [UInt32(words.count)])])
    return readBuffer(buf, words.count, as: UInt64.self)
}

func pairBits(_ hi: Float, _ lo: Float) -> UInt64 { UInt64(hi.bitPattern) | (UInt64(lo.bitPattern) << 32) }
func pairOf(_ w: UInt64) -> (Float, Float) { (Float(bitPattern: UInt32(truncatingIfNeeded: w)), Float(bitPattern: UInt32(w >> 32))) }

let specialDoubles: [(String, Double)] = {
    var s: [(String, Double)] = [
        ("+0", 0.0), ("-0", -0.0), ("+inf", .infinity), ("-inf", -.infinity),
        ("quiet NaN", .nan), ("-quiet NaN", -.nan), ("signaling NaN", .signalingNaN),
        ("NaN with payload", Double(bitPattern: 0x7FF0_0000_DEAD_BEEF)),
        ("smallest subnormal double", Double.leastNonzeroMagnitude), ("-largest subnormal double", -Double(bitPattern: 0x000F_FFFF_FFFF_FFFF)),
        ("smallest normal double", Double.leastNormalMagnitude), ("2^-151", 0x1p-151), ("2^-150 (tie to 0)", 0x1p-150),
        ("2^-150 + tiny (to 2^-149)", 0x1p-150 * (1 + 0x1p-52)), ("2^-149", 0x1p-149), ("-3 * 2^-150 (tie to even)", -3 * 0x1p-150),
        ("2^-127 + 2^-140", 0x1p-127 + 0x1p-140), ("2^-126", 0x1p-126), ("2^-75 (slow path edge)", 0x1p-75 * 1.2345678901234),
        ("2^-74 (fast path edge)", 0x1p-74 * 1.2345678901234), ("2^-102 (lo leaves normal range)", 0x1p-102 * 1.2345678901234),
        ("1", 1.0), ("-1", -1.0), ("1 + 2^-24 (tie, even)", 1 + 0x1p-24), ("1 + 3*2^-24 (tie, odd)", 1 + 3 * 0x1p-24),
        ("1 + 2^-24 + 2^-52", 1 + 0x1p-24 + 0x1p-52), ("1 - 2^-53", 1 - 0x1p-53), ("1 + 2^-52", 1 + 0x1p-52),
        ("1 + 2^-23 + 2^-24 - 2^-52 (below a tie, odd hi)", 1 + 0x1p-23 + 0x1p-24 - 0x1p-52),
        ("-(1 + 2^-23) + 2^-24 + 2^-52 (below a tie, odd hi)", -(1 + 0x1p-23) + 0x1p-24 + 0x1p-52),
        ("2^-110 (1 + 2^-23) + 2^-134 - 2^-162 (below a tie, subnormal lo)", 0x1p-110 * (1 + 0x1p-23) + 0x1p-134 - 0x1p-162),
        ("pi", Double.pi), ("-1e7 / 3", -1e7 / 3), ("0.002", 0.002), ("2^32", 0x1p32),
        ("FLT_MAX", Double(Float.greatestFiniteMagnitude)),
        ("FLT_MAX + half ulp - 2^76 (below tie)", Double(Float.greatestFiniteMagnitude) + 0x1p103 - 0x1p76),
        ("FLT_MAX + half ulp (tie to inf)", Double(Float.greatestFiniteMagnitude) + 0x1p103),
        ("2^128", 0x1p128), ("-2^200", -0x1p200), ("DBL_MAX", Double.greatestFiniteMagnitude),
    ]
    s.append(("2^127 * (2 - 2^-30)", 0x1p127 * (2 - 0x1p-30)))
    return s
}()

func runConvert() {
    print("## 3b. IEEE double <-> df64 conversion kernels (df64FromIEEE, df64ToIEEE, in place)")
    print("")
    let lib = makeLibrary(stdHeader + df64Source + convertSource)
    let fromIEEE = makePipeline(lib, "df64FromIEEE"), toIEEE = makePipeline(lib, "df64ToIEEE")

    // Special cases, printed one by one.
    let specials = specialDoubles.map { $0.1.bitPattern }
    let decoded = convertInPlace(fromIEEE, specials)
    let encoded = convertInPlace(toIEEE, decoded)
    print("Decode reference: hi = RN(d), lo = RN(d - hi) moved one float towards zero when it is half an ulp of an odd hi; the decoded pair must also be a double-word number (hi = RN(hi + lo)).")
    print("")
    print("| Input | Bits | GPU hi | GPU lo | Decode matches reference | Encode(decode(x)) | Round trip |")
    print("| --- | --- | --- | --- | --- | --- | --- |")
    var specialFailures = 0
    for (i, (name, d)) in specialDoubles.enumerated() {
        let (hi, lo) = pairOf(decoded[i])
        let (rh, rl) = decodeReference(d)
        let decodeOK = sameFloat(hi, rh) && sameFloat(lo, rl) && isDoubleWord(hi, lo)
        let back = Double(bitPattern: encoded[i])
        let encodeOK = sameDouble(back, encodeReference(hi, lo))
        let representable = !d.isFinite || Double(lo) == d - Double(hi)
        let roundTrip = representable ? (sameDouble(back, d) ? "exact" : "CHANGED") : (back.isFinite ? String(format: "rel %.1e (not representable)", abs(back - d) / abs(d)) : "inf")
        if !decodeOK || !encodeOK || roundTrip == "CHANGED" { specialFailures += 1 }
        print("| \(name) | 0x\(String(d.bitPattern, radix: 16)) | \(hi) | \(lo) | \(decodeOK ? "yes" : "NO") | \(encodeOK ? "matches RN(hi+lo)" : "NO: \(back)") | \(roundTrip) |")
    }
    print("")
    print("Special cases failing any check: \(specialFailures) of \(specialDoubles.count).")
    print("")

    // Bulk sets.
    var rng = SplitMix64(state: 0x15_3000)
    let count = 1 << 20
    let sets: [(String, [UInt64])] = [
        ("uniform random 64-bit patterns (all exponents, NaN, inf, subnormal)", (0..<count).map { _ in rng.next() }),
        ("random doubles, exponent uniform in [-160, 140], random sign", (0..<count).map { _ in
            let m = 1 + rng.uniform()
            return (Double(sign: rng.next() & 1 == 1 ? .minus : .plus, exponent: Int(rng.next() % 301) - 160, significand: m)).bitPattern }),
        ("MD magnitudes, +-[1e-4, 1e7]", (0..<count).map { _ in rng.logUniform(1e-4, 1e7).bitPattern }),
        ("within 32 double ulps of a float tie, odd hi, exponents -140..127", (0..<count).map { _ in
            var h = Float(sign: rng.next() & 1 == 1 ? .minus : .plus, exponent: Int(rng.next() % 268) - 140, significand: Float(1 + rng.uniform()))
            if h.bitPattern & 1 == 0 { h = h.nextUp }
            let side: Double = rng.next() & 1 == 1 ? 1 : -1
            return (Double(h) + side * (Double(h.ulp) / 2 - Double(Int(rng.next() % 33) - 1) * Double(h.ulp) * 0x1p-29)).bitPattern }),
    ]
    print("| Set | Doubles | Decode bit-exact | Decoded double-word pairs | Encode(decode) = RN(hi+lo) bit-exact | Representable | Representable round trips exact | Decode idempotent after encode (a zero lo may change sign) | Max decode error, 2^-48 units, 2^-100 <= |d| <= FLT_MAX |")
    print("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    for (name, words) in sets {
        let dec = convertInPlace(fromIEEE, words)
        let enc = convertInPlace(toIEEE, dec)
        let dec2 = convertInPlace(fromIEEE, enc)
        var decodeOK = 0, doubleWord = 0, encodeOK = 0, representable = 0, roundTrip = 0, idempotent = 0
        var maxDecodeError = 0.0
        for i in 0..<words.count {
            let d = Double(bitPattern: words[i])
            let (hi, lo) = pairOf(dec[i])
            let (rh, rl) = decodeReference(d)
            if sameFloat(hi, rh) && sameFloat(lo, rl) { decodeOK += 1 }
            else if verbose { print("    decode mismatch: d=\(d) (0x\(String(words[i], radix: 16))) gpu=(\(hi), \(lo)) want=(\(rh), \(rl))") }
            if isDoubleWord(hi, lo) { doubleWord += 1 }
            if abs(d) >= 0x1p-100 && abs(d) <= Double(Float.greatestFiniteMagnitude) {
                // Exact: both partial differences are exact in double, and d - hi and lo are within 2^-24 |d|.
                maxDecodeError = max(maxDecodeError, abs((d - Double(hi)) - Double(lo)) / abs(d) / unit48)
            }
            let back = Double(bitPattern: enc[i])
            if sameDouble(back, encodeReference(hi, lo)) { encodeOK += 1 }
            else if verbose { print("    encode mismatch: d=\(d) (0x\(String(words[i], radix: 16))) hi=\(hi) lo=\(lo) gpu=\(back) want=\(encodeReference(hi, lo))") }
            if d.isNaN || !d.isFinite || !Float(d).isFinite || Double(lo) == d - Double(hi) {
                representable += 1
                if sameDouble(back, d) || (d.isNaN && back.isNaN) || (!Float(d).isFinite && back.isInfinite) { roundTrip += 1 }
            }
            let (h2, l2) = pairOf(dec2[i])
            if sameFloat(h2, hi) && l2 == lo { idempotent += 1 }
            else if verbose { print("    not idempotent: d=\(d) (0x\(String(words[i], radix: 16))) first=(\(hi), \(lo)) second=(\(h2), \(l2))") }
        }
        print("| \(name) | \(words.count) | \(decodeOK) | \(doubleWord) | \(encodeOK) | \(representable) | \(roundTrip) | \(idempotent) | \(String(format: "%.3f", maxDecodeError)) |")
    }
    print("")
    print("Representable: the double equals hi + lo exactly (its bits fit in two floats), or it is NaN or overflows float. For those a round trip must return the input (inf for values beyond float range, NaN for NaN).")
    print("")

    // Encode of pairs that are not double-word numbers: the verifier's overflow cases and the documented
    // conventions for (0, lo) and a non-finite lo.
    let fltMax = Float.greatestFiniteMagnitude
    let edgePairs: [(String, Float, Float)] = [
        ("(FLT_MAX, 2^126)", fltMax, 0x1p126), ("(-FLT_MAX, -2^126)", -fltMax, -0x1p126),
        ("(1.9 * 2^127, 0.2 * 2^127)", 1.9 * 0x1p127, 0.2 * 0x1p127), ("(FLT_MAX, 2^104 (1 + 2^-23))", fltMax, 0x1p104 * (1 + 0x1p-23)),
        ("(FLT_MAX, 2^103)", fltMax, 0x1p103), ("(FLT_MAX, -FLT_MAX)", fltMax, -fltMax),
        ("(0, 2^-10)", 0, 0x1p-10), ("(-0, 2^-10)", -0.0, 0x1p-10), ("(0, 2^-140)", 0, 0x1p-140), ("(-0, +0)", -0.0, 0),
        ("(1, NaN)", 1, .nan), ("(1, inf)", 1, .infinity), ("(1, -inf)", 1, -.infinity), ("(inf, 1)", .infinity, 1),
        ("(2^-120, 2^-140)", 0x1p-120, 0x1p-140), ("(1, -2^-25)", 1, -0x1p-25),
    ]
    let edgeOut = convertInPlace(toIEEE, edgePairs.map { pairBits($0.1, $0.2) })
    print("| Pair (hi, lo) | GPU encode | RN(hi + lo) | Match |")
    print("| --- | --- | --- | --- |")
    var edgeFailures = 0
    for (i, (name, hi, lo)) in edgePairs.enumerated() {
        let got = Double(bitPattern: edgeOut[i]), want = encodeReference(hi, lo)
        if !sameDouble(got, want) { edgeFailures += 1 }
        print("| \(name) | \(got) | \(want) | \(sameDouble(got, want) ? "yes" : "NO") |")
    }
    print("")
    print("Edge pairs failing: \(edgeFailures) of \(edgePairs.count).")
    print("")

    // Encode of random pairs over the whole finite float range (subnormal hi included), in four classes.
    let classes = ["double-word pairs", "unnormalized, |lo| up to 4 ulp(hi)", "unnormalized, |lo| / |hi| log-uniform in [2^-60, 1]", "|hi| >= 2^126, |lo| / |hi| log-uniform in [2^-30, 1]"]
    var pairs = [UInt64](), pairClass = [Int]()
    for k in 0..<count {
        let c = k % 4
        var hi: Float
        repeat { hi = Float(bitPattern: UInt32(truncatingIfNeeded: rng.next())) } while !hi.isFinite || (c == 3 && abs(hi) < 0x1p126)
        let lo: Float
        switch c {
        case 0: (hi, lo) = split(Double(hi) + Double(hi.ulp) * rng.uniform(-0.5, 0.5))
        case 1: lo = Float(Double(hi.ulp) * rng.uniform(-4, 4))
        case 2: lo = Float(Double(hi) * rng.logUniform(0x1p-60, 1))
        default: lo = Float(Double(hi) * rng.logUniform(0x1p-30, 1))
        }
        pairs.append(pairBits(hi, lo)); pairClass.append(c)
    }
    let encPairs = convertInPlace(toIEEE, pairs)
    var pairOK = [0, 0, 0, 0], pairTotal = [0, 0, 0, 0]
    for i in 0..<pairs.count {
        let (hi, lo) = pairOf(pairs[i])
        pairTotal[pairClass[i]] += 1
        if sameDouble(Double(bitPattern: encPairs[i]), encodeReference(hi, lo)) { pairOK[pairClass[i]] += 1 }
        else if verbose { print("    pair mismatch: hi=\(hi) (0x\(String(hi.bitPattern, radix: 16))) lo=\(lo) (0x\(String(lo.bitPattern, radix: 16))) gpu=\(Double(bitPattern: encPairs[i])) want=\(encodeReference(hi, lo))") }
    }
    print("| Random pairs, hi over all finite floats | Pairs | Encode = RN(hi + lo) bit-exact |")
    print("| --- | ---: | ---: |")
    for c in 0..<4 { print("| \(classes[c]) | \(pairTotal[c]) | \(pairOK[c]) |") }
    print("")
}

// MARK: - Program composition (prelude + precision block + defines + rewritten Common source)

enum Precision: CaseIterable {
    case single, floatMixed, df64Pairs, df64IEEE
    var label: String {
        switch self {
        case .single: return "single (no USE_MIXED_PRECISION)"
        case .floatMixed: return "float mixed (USE_MIXED_PRECISION, mixed = float)"
        case .df64Pairs: return "df64 mixed, pair storage"
        case .df64IEEE: return "df64 mixed, IEEE storage"
        }
    }
}

// Mirrors OpenCLContext::createProgram in mixed mode: USE_MIXED_PRECISION and SUPPORTS_DOUBLE_PRECISION,
// real = float, mixed = double (here df64), make_mixedN/convert_mixed4 map to the double versions.
func precisionBlock(_ p: Precision, supportsDouble: Bool = true) -> String {
    let real = """
    typedef float real;
    typedef float2 real2;
    typedef float3 real3;
    typedef float4 real4;
    #define make_real2 float2
    #define make_real3 float3
    #define make_real4 float4
    #define convert_real4(x) (float4(x))

    """
    if p == .single || p == .floatMixed {
        // floatMixed: the mixed-precision code paths (posqCorrection traffic included) with mixed = float,
        // the baseline that isolates the cost of df64 itself.
        return (p == .floatMixed ? "#define USE_MIXED_PRECISION 1\n" : "") + real + """
        typedef float mixed;
        typedef float2 mixed2;
        typedef float3 mixed3;
        typedef float4 mixed4;
        #define make_mixed2 float2
        #define make_mixed3 float3
        #define make_mixed4 float4
        #define convert_mixed4(x) (float4(x))

        """
    }
    var s = "#define USE_MIXED_PRECISION 1\n"
    if supportsDouble { s += "#define SUPPORTS_DOUBLE_PRECISION\n" }
    if p == .df64IEEE { s += "#define DF64_IEEE_STORAGE\n" }
    s += df64Source + "\n" + real + """
    typedef df64 mixed;
    typedef df64_2 mixed2;
    typedef df64_3 mixed3;
    typedef df64_4 mixed4;
    #define make_mixed2 df64_2
    #define make_mixed3 df64_3
    #define make_mixed4 df64_4
    #define convert_mixed4(x) (df64_4(x))

    """
    // metal_stdlib reserves the names double2..4 as typedefs, so they can only be macros.
    if supportsDouble {
        s += """
        #define double df64
        #define double2 df64_2
        #define double3 df64_3
        #define double4 df64_4
        #define make_double2 df64_2
        #define make_double3 df64_3
        #define make_double4 df64_4
        #define convert_double4(x) (df64_4(x))

        """
    }
    return s
}

// The lab prelude with its single-precision block removed; the precision block goes right after
// `using namespace metal;`, before the prelude redefines the `thread` keyword.
let preludeWithoutPrecision: (String, String) = {
    let dropped = try! NSRegularExpression(pattern: #"^(typedef float[234]? (real|mixed)[234]?;|#define (make_(real|mixed)[234]|convert_(real|mixed)4)\b.*)$"#, options: [.anchorsMatchLines])
    let text = dropped.stringByReplacingMatches(in: preludeSource, range: NSRange(preludeSource.startIndex..., in: preludeSource), withTemplate: "")
    let marker = "using namespace metal;\n"
    let r = text.range(of: marker)!
    return (String(text[..<r.upperBound]), String(text[r.upperBound...]))
}()

func composeProgram(_ body: String, _ p: Precision, defines: String, supportsDouble: Bool = true) -> String {
    preludeWithoutPrecision.0 + precisionBlock(p, supportsDouble: supportsDouble) + preludeWithoutPrecision.1 + "\n" + defines + "\n" + body
}

// The two mechanical rewrites from experiment 005 (value parameters to constant references, vector literals).
func rewriteKernelSignatures(_ source: String) -> String {
    let regex = try! NSRegularExpression(pattern: #"(?:KERNEL|__kernel)\s+void\s+(\w+)\s*\(([\s\S]*?)\)\s*\{"#)
    let ns = source as NSString
    var result = ""
    var last = 0
    for m in regex.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
        result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
        let name = ns.substring(with: m.range(at: 1))
        var lines: [String] = [], copies: [String] = []
        for line in ns.substring(with: m.range(at: 2)).components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("#") { lines.append(line); copies.append(line); continue }
            var parts: [String] = []
            for part in line.components(separatedBy: ",") {
                let t = part.trimmingCharacters(in: .whitespacesAndNewlines)
                var words = t.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if t.isEmpty || t.contains("*") || t.contains("PARAMETER_ARGUMENTS") || t.contains("EXTRA_ARGS") || words.count < 2 {
                    parts.append(part)
                    continue
                }
                let param = words.removeLast()
                let lead = part.prefix(while: { $0.isWhitespace })
                parts.append("\(lead)constant \(words.joined(separator: " "))& _in_\(param)")
                copies.append("\(words.filter { $0 != "const" }.joined(separator: " ")) \(param) = _in_\(param);")
            }
            lines.append(parts.joined(separator: ","))
        }
        result += "kernel void \(name)(\(lines.joined(separator: "\n"))) {" + (copies.isEmpty ? "" : "\n    " + copies.joined(separator: "\n    "))
        last = m.range.location + m.range.length
    }
    result += ns.substring(from: last)
    let literal = try! NSRegularExpression(pattern: #"\(\s*(real4|float8|float4|float2|float3|int2|int3|int4|uint2|uint3|uint4|short2|short3|short4)\s*\)\s*\("#)
    return literal.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1(")
}

// MARK: - 3c. Compile census

// Host-side defines, as in experiment 002.
let globalDefines: [String: String] = [
    "PADDED_NUM_ATOMS": "1024", "NUM_ATOMS": "1000", "TILE_SIZE": "32", "WARP_SIZE": "32", "TileSize": "32",
    "M_PI": "3.14159265358979323846", "ONE_4PI_EPS0": "138.935456f", "EPSILON0": "(1.0f/(4.0f*M_PI*ONE_4PI_EPS0))",
    "USE_CUTOFF": "1", "USE_PERIODIC": "1", "WORK_GROUP_SIZE": "64", "THREAD_BLOCK_SIZE": "64", "FORCE_WORK_GROUP_SIZE": "64",
    "LOCAL_MEMORY_SIZE": "64", "TEMP_SIZE": "64", "LOCAL_BUFFER_SIZE": "64", "KE_WORK_GROUP_SIZE": "64",
    "FIND_NEIGHBORS_THREAD_BLOCK_SIZE": "64", "FIND_NEIGHBORS_WORKGROUP_SIZE": "64", "NUM_BLOCKS": "32",
    "PADDED_NUM_ACTIVE": "1024", "NUM_ACTIVE": "1000", "WARPS_IN_BLOCK": "2", "CUTOFF": "1.0f", "CUTOFF_SQUARED": "1.0f",
    "COMPONENTS": "1", "INVERSE_TOTAL_MASS": "1.0f", "PI": "3.14159265358979323846", "MAX_CUTOFF": "1.0f",
    "NEIGHBOR_BLOCK_SIZE": "32", "SURFACE_AREA_FACTOR": "1.0f", "PROBE_RADIUS": "0.14f", "DIELECTRIC_OFFSET": "0.009f",
    "NUM_TILES_WITH_EXCLUSIONS": "10", "FIRST_EXCLUSION_TILE": "0", "LAST_EXCLUSION_TILE": "10", "FIRST_TILE": "0",
    "LAST_TILE": "10", "NUM_TILES": "10", "PADDED_CUTOFF_SQUARED": "1.0f", "KMAX_X": "10", "KMAX_Y": "10", "KMAX_Z": "10",
    "EXP_COEFFICIENT": "-0.25f", "PME_ORDER": "5", "NUM_INDICES": "0", "RECIP_EXP_FACTOR": "1.0f", "GRID_SIZE_X": "32",
    "GRID_SIZE_Y": "32", "GRID_SIZE_Z": "32", "EPSILON_FACTOR": "11.787f", "CHARGE": "pos.w", "CHARGE_BUFFER_SIZE": "64",
    "EWALD_ALPHA": "0.5f", "PREFACTOR": "1.0f", "BOLTZ": "0.008314462618f",
    "BEGIN_YS_LOOP": "const real arr[1] = {1.0f}; for(int i=0;i<1;++i) { const real ys = arr[i];", "END_YS_LOOP": "}",
    "MTS": "1", "NUM_PARTICLES": "1000", "NUM_ELECTRODE_PARTICLES": "100", "CHUNK_SIZE": "4", "CHUNK_COUNT": "8",
    "PADDED_PROBLEM_SIZE": "128", "ERROR_TARGET": "1e-4f", "THREAD_BLOCK_COUNT": "8", "PLASMA_SCALE": "1.0f",
    "NUM_EXCLUSION_TILES": "10", "NUM_CCMA_ATOMS": "100", "NUM_CCMA_CONSTRAINTS": "50", "NUM_2_AVERAGE": "10",
    "NUM_3_AVERAGE": "10", "NUM_OUT_OF_PLANE": "10", "NUM_LOCAL_COORDS": "10", "NUM_SYMMETRY": "10", "NUM_VECTORS": "10",
    "LBFGS_FTOL": "1e-4f", "LBFGS_WOLFE": "0.9f", "LBFGS_SCALE_DOWN": "0.1f", "LBFGS_SCALE_UP": "1.1f",
    "LBFGS_MIN_STEP": "1e-6f", "LBFGS_MAX_STEP": "1e6f", "NUM_DONORS": "100", "NUM_ACCEPTORS": "100",
    "NUM_DONOR_BLOCKS": "4", "NUM_ACCEPTOR_BLOCKS": "4",
]

// Host-substituted placeholders, as in experiment 002.
func fileReplacements(_ file: String) -> [String: String] {
    switch file {
    case "customCVForce.cc": return ["PARAMETER_ARGUMENTS": "", "ADD_FORCES": ""]
    case "customCentroidBond.cc": return ["EXTRA_ARGS": "", "INIT_PARAM_DERIVS": "", "NUM_BONDS": "100", "COMPUTE_FORCE": "", "SAVE_PARAM_DERIVS": ""]
    case "customHbondForce.cc": return ["PARAMETER_ARGUMENTS": "", "COMPUTE_FORCE": ""]
    case "customIntegratorPerDof.cc": return ["PARAMETER_ARGUMENTS": "", "COMPUTE_STEP": ""]
    case "customManyParticle.cc":
        return ["PARAMETER_ARGUMENTS": "", "COMPUTE_INTERACTION": "", "COMPUTE_TYPE_INDEX": "0", "IS_VALID_COMBINATION": "true",
                "FIND_ATOMS_FOR_COMBINATION_INDEX": "", "NUM_CANDIDATE_COMBINATIONS": "1", "VERIFY_CUTOFF": "",
                "VERIFY_EXCLUSIONS": "", "PERMUTE_ATOMS": "", "LOAD_PARTICLE_DATA": ""]
    case "customNonbondedGroups.cc":
        return ["PARAMETER_ARGUMENTS": "", "ATOM_PARAMETER_DATA": "float params1;", "COMPUTE_INTERACTION": "", "INIT_DERIVATIVES": "",
                "SAVE_DERIVATIVES": "", "LOAD_ATOM1_PARAMETERS": "", "LOAD_ATOM2_PARAMETERS": "", "LOAD_LOCAL_PARAMETERS": ""]
    case "customGBEnergyPerParticle.cc":
        return ["PARAMETER_ARGUMENTS": "", "COMPUTE_ENERGY": "", "INIT_PARAM_DERIVS": "", "SAVE_PARAM_DERIVS": "", "REDUCE_DERIVATIVES": ""]
    case "customGBEnergyN2.cc", "customGBEnergyN2_cpu.cc":
        return ["ATOM_PARAMETER_DATA": "float params1;", "PARAMETER_ARGUMENTS": "", "LOAD_LOCAL_PARAMETERS_FROM_1": "",
                "LOAD_LOCAL_PARAMETERS_FROM_GLOBAL": "", "CLEAR_LOCAL_DERIVATIVES": "", "LOAD_ATOM1_PARAMETERS": "",
                "LOAD_ATOM2_PARAMETERS": "", "DECLARE_ATOM1_DERIVATIVES": "", "RECORD_DERIVATIVE_2": "", "STORE_DERIVATIVES_1": "",
                "STORE_DERIVATIVES_2": "", "INIT_PARAM_DERIVS": "", "SAVE_PARAM_DERIVS": "", "COMPUTE_INTERACTION": ""]
    case "qtb.cc": return ["FFT_FORWARD": "", "RECIP_DATA": "data0", "FFT_BACKWARD": "", "ADAPTATION_FFT": "", "ADAPTATION_RECIP": "data0"]
    default: return [:]
    }
}

let definesBlock = globalDefines.sorted { $0.key < $1.key }.map { "#define \($0.key) \($0.value)" }.joined(separator: "\n")

func censusSource(_ file: String, edited: Bool = false) -> String {
    var raw = readFile("\(kernelsDir)/\(file)")
    if edited { raw = applyCommonEdits(file, raw) }
    for (k, v) in fileReplacements(file) { raw = raw.replacingOccurrences(of: k, with: v) }
    if file == "customCentroidBond.cc" || file == "customManyParticle.cc" {
        raw = readFile("\(kernelsDir)/pointFunctions.cc") + "\n" + raw
    }
    return rewriteKernelSignatures(raw)
}

// The Common source edits df64 needs beyond the prelude: a float literal in one arm of ?: against a
// mixed in the other is ambiguous for a class type, so the literal becomes (mixed) 0. The result is
// the same in OpenCL and CUDA, where the literal was promoted to double anyway.
let commonEdits: [String: [(String, String)]] = [
    "noseHooverIntegrator.cc": [
        ("v1.w == 0.0f ? 0.0f : 1.0f / v1.w", "v1.w == 0.0f ? (mixed) 0 : 1.0f / v1.w"),
        ("v2.w == 0.0f ? 0.0f : 1.0f / v2.w", "v2.w == 0.0f ? (mixed) 0 : 1.0f / v2.w"),
        ("(m1 + m2)/(m1 * m2) : 0.0f", "(m1 + m2)/(m1 * m2) : (mixed) 0"),
        ("1.0f /(m1 + m2) : 0.0f", "1.0f /(m1 + m2) : (mixed) 0"),
        ("1.0/velm[atom1].w : 0.0;", "1.0/velm[atom1].w : (mixed) 0;"),
        ("1.0/velm[atom2].w : 0.0;", "1.0/velm[atom2].w : (mixed) 0;"),
        ("1.0 /(m1 + m2) : 0.0;", "1.0 /(m1 + m2) : (mixed) 0;"),
    ],
    "integrationUtilities.cc": [
        ("reducedMass[index]*diff/rrpr : 0.0f", "reducedMass[index]*diff/rrpr : (mixed) 0"),
    ],
]

func applyCommonEdits(_ file: String, _ source: String) -> String {
    var s = source
    for (from, to) in commonEdits[file] ?? [] {
        guard s.contains(from) else {
            fputs("Common edit for \(file) no longer matches: \(from)\n", stderr)
            exit(1)
        }
        s = s.replacingOccurrences(of: from, with: to)
    }
    return s
}

func compileErrors(_ source: String) -> [String] {
    do {
        _ = try device.makeLibrary(source: source, options: compileOptions(.safe))
        return []
    } catch {
        if verbose && ProcessInfo.processInfo.environment["DUMP"] != nil { print("\(error)") }
        let lines = "\(error)".components(separatedBy: "\n").filter { $0.contains("error:") }
        var seen = Set<String>()
        return lines.map { $0.replacingOccurrences(of: #"^.*?program_source:\d+:\d+: "#, with: "", options: .regularExpression) }
            .filter { seen.insert($0).inserted }
    }
}

func runCensus() {
    print("## 3c. Compile census: Common kernels that mention mixed precision")
    print("")
    let commit = (try? String(contentsOfFile: "\(kernelsDir)/COMMIT", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
    let files = (try? FileManager.default.contentsOfDirectory(atPath: kernelsDir))?.filter { $0.hasSuffix(".cc") }.sorted() ?? []
    let mixedFiles = files.filter { readFile("\(kernelsDir)/\($0)").range(of: "mixed", options: .caseInsensitive) != nil }
    print("OpenMM commit \(commit), \(files.count) kernel files, \(mixedFiles.count) mention `mixed` (case-insensitive, so USE_MIXED_PRECISION counts).")
    print("Program = lab prelude (005) with its precision block replaced + defines from 002 + the 005 rewrites. Mixed mode defines USE_MIXED_PRECISION and SUPPORTS_DOUBLE_PRECISION as OpenCLContext does, with `double` mapped to df64.")
    print("")
    print("| File | single | df64 pairs | df64 IEEE | df64 without SUPPORTS_DOUBLE_PRECISION | df64 pairs + Common edits | df64 errors not in single | First df64 error |")
    print("| --- | --- | --- | --- | --- | --- | ---: | --- |")
    var counts = [0, 0, 0, 0, 0]
    for file in mixedFiles {
        let body = censusSource(file)
        let results = [
            compileErrors(composeProgram(body, .single, defines: definesBlock)),
            compileErrors(composeProgram(body, .df64Pairs, defines: definesBlock)),
            compileErrors(composeProgram(body, .df64IEEE, defines: definesBlock)),
            compileErrors(composeProgram(body, .df64Pairs, defines: definesBlock, supportsDouble: false)),
            commonEdits[file] == nil ? nil : compileErrors(composeProgram(censusSource(file, edited: true), .df64Pairs, defines: definesBlock)),
        ].map { $0 ?? compileErrors(composeProgram(body, .df64Pairs, defines: definesBlock)) }
        for (i, r) in results.enumerated() where r.isEmpty { counts[i] += 1 }
        var marks = results.map { $0.isEmpty ? "ok" : "FAIL" }
        if commonEdits[file] == nil { marks[4] = "(no edit) " + marks[4] }
        let single = Set(results[0])
        let df64Only = results[1].filter { !single.contains($0) }
        let first = (df64Only.first ?? results[1].first ?? results[3].first ?? "").replacingOccurrences(of: "|", with: "\\|")
        print("| \(file) | \(marks.joined(separator: " | ")) | \(df64Only.count) | \(first) |")
    }
    let total = mixedFiles.count
    print("| **compiled** | \(counts.map { "\($0)/\(total)" }.joined(separator: " | ")) | | |")
    print("")
    if verbose {
        for file in mixedFiles {
            let errors = compileErrors(composeProgram(censusSource(file), .df64Pairs, defines: definesBlock))
            if errors.isEmpty { continue }
            print("### \(file)")
            for e in errors.prefix(12) { print("    \(e)") }
        }
    }
}

// MARK: - 3d. Integration kernel cost

func busyProcesses() -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-l", "ninja|clang|cc1plus"]
    let pipe = Pipe()
    p.standardOutput = pipe
    try? p.run()
    p.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return out.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: ", ")
}

struct Kernel {
    let pso: MTLComputePipelineState
    let bindings: [String: Int]
}

func makeKernel(_ lib: MTLLibrary, _ name: String) -> Kernel {
    let f = lib.makeFunction(name: name)!
    var reflection: MTLComputePipelineReflection?
    let pso = try! device.makeComputePipelineState(function: f, options: [.bindingInfo], reflection: &reflection)
    var map = [String: Int]()
    for b in reflection!.bindings where b.type == .buffer { map[b.name] = b.index }
    return Kernel(pso: pso, bindings: map)
}

// Buffers of one simulated system in the storage format of one precision mode.
final class System {
    let n: Int
    let precision: Precision
    var buffers = [String: MTLBuffer]()
    var scalars = [String: [UInt32]]()

    init(n: Int, precision: Precision, seed: UInt64) {
        self.n = n
        self.precision = precision
        var rng = SplitMix64(state: seed)
        let padded = (n + 31) / 32 * 32
        var velm = [Double](), pos = [Float](), force = [Int64](repeating: 0, count: 3 * padded), random = [Float]()
        for i in 0..<n {
            let invMass = 1 / rng.uniform(1, 32)
            velm += [rng.uniform(-1, 1), rng.uniform(-1, 1), rng.uniform(-1, 1), invMass]
            pos += [Float(rng.uniform(0, 10)), Float(rng.uniform(0, 10)), Float(rng.uniform(0, 10)), 0]
            for d in 0..<3 { force[i + d * padded] = Int64(rng.uniform(-1e3, 1e3) * 0x1p32) }
        }
        for _ in 0..<(4 * (n + 64)) { random.append(Float(rng.uniform(-1.7, 1.7))) }
        buffers["velm"] = mixedBuffer(velm)
        buffers["posDelta"] = mixedBuffer([Double](repeating: 0, count: 4 * n))
        buffers["oldDelta"] = mixedBuffer([Double](repeating: 0, count: 4 * n))
        buffers["dt"] = mixedBuffer([0.002, 0.002])
        buffers["paramBuffer"] = mixedBuffer([0.99, 0.1])
        buffers["posq"] = makeBuffer(pos)
        buffers["posqCorrection"] = makeBuffer([Float](repeating: 0, count: 4 * n))
        buffers["force"] = makeBuffer(force)
        buffers["random"] = makeBuffer(random)
        scalars["_in_numAtoms"] = [UInt32(n)]
        scalars["_in_paddedNumAtoms"] = [UInt32(padded)]
        scalars["_in_randomIndex"] = [0]
    }

    func mixedBuffer(_ values: [Double]) -> MTLBuffer {
        switch precision {
        case .single, .floatMixed: return makeBuffer(values.map { Float($0) })
        case .df64Pairs: return makeBuffer(values.flatMap { d -> [Float] in let (h, l) = split(d); return [h, l] })
        case .df64IEEE: return makeBuffer(values)
        }
    }

    func mixedValues(_ name: String, _ count: Int) -> [Double] {
        let b = buffers[name]!
        switch precision {
        case .single, .floatMixed: return readBuffer(b, count, as: Float.self).map { Double($0) }
        case .df64Pairs: let f = readBuffer(b, 2 * count, as: Float.self); return (0..<count).map { value(f[2 * $0], f[2 * $0 + 1]) }
        case .df64IEEE: return readBuffer(b, count, as: Double.self)
        }
    }

    func encode(_ enc: MTLComputeCommandEncoder, _ k: Kernel) {
        enc.setComputePipelineState(k.pso)
        for (name, index) in k.bindings {
            if let b = buffers[name] { enc.setBuffer(b, offset: 0, index: index) }
            else if let s = scalars[name] { s.withUnsafeBytes { enc.setBytes($0.baseAddress!, length: $0.count, index: index) } }
            else { fputs("unbound argument \(name)\n", stderr); exit(3) }
        }
        let threads = (n + 63) / 64 * 64
        enc.dispatchThreads(MTLSize(width: threads, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
    }

    // GPU seconds per repetition of `kernels`, from one command buffer of `reps` repetitions.
    func time(_ kernels: [Kernel], reps: Int) -> Double {
        let cb = queue.makeCommandBuffer()!
        let enc = cb.makeComputeCommandEncoder()!
        for _ in 0..<reps { for k in kernels { encode(enc, k) } }
        enc.endEncoding()
        commit(cb)
        return (cb.gpuEndTime - cb.gpuStartTime) / Double(reps)
    }
}

let timingReps = 200
let timingRounds = 21

let integrators: [(String, String, [String])] = [
    ("Verlet", "verlet.cc", ["integrateVerletPart1", "integrateVerletPart2"]),
    ("LangevinMiddle", "langevinMiddle.cc", ["integrateLangevinMiddlePart1", "integrateLangevinMiddlePart2", "integrateLangevinMiddlePart3"]),
]

func runTiming() {
    print("## 3d. Cost of df64 in Common integration kernels")
    print("")
    let before = busyProcesses()
    print("Build processes before timing (pgrep ninja|clang|cc1plus): \(before.isEmpty ? "none" : before)")
    print("")
    print("Clock: GPU, MTLCommandBuffer gpuEndTime - gpuStartTime, one compute encoder per command buffer. One thread per atom, 64-thread threadgroups. Kernels are the unmodified Common sources through the lab prelude and the 005 rewrites. Variants: single (real = mixed = float, no USE_MIXED_PRECISION); float mixed (USE_MIXED_PRECISION with mixed = float, so posqCorrection is read and written; no SUPPORTS_DOUBLE_PRECISION); df64 pairs and df64 IEEE (USE_MIXED_PRECISION and SUPPORTS_DOUBLE_PRECISION, mixed = df64).")
    print("")
    let libraries = Dictionary(uniqueKeysWithValues: Precision.allCases.map { p in
        (p, integrators.map { makeLibrary(composeProgram(rewriteKernelSignatures(readFile("\(kernelsDir)/\($0.1)")), p, defines: "")) })
    })

    // Numerical check: one Verlet step in each mode against a CPU double reference of the same step.
    print("### One Verlet step against CPU double (23,558 atoms)")
    print("")
    print("Errors are normwise: max |gpu - ref| over all components divided by max |ref|.")
    print("")
    print("| Mode | velocity error | position error (posq + posqCorrection) | max difference from pair storage, velocity |")
    print("| --- | ---: | ---: | ---: |")
    var velocityByMode = [Precision: [Double]]()
    for p in Precision.allCases {
        let s = System(n: 23_558, precision: p, seed: 0x15_4000)
        let v0 = System(n: 23_558, precision: .df64IEEE, seed: 0x15_4000)
        let v = v0.mixedValues("velm", 4 * s.n)
        let pos0 = readBuffer(v0.buffers["posq"]!, 4 * s.n, as: Float.self)
        let padded = Int(s.scalars["_in_paddedNumAtoms"]![0])
        let force = readBuffer(v0.buffers["force"]!, 3 * padded, as: Int64.self)
        let cb = queue.makeCommandBuffer()!
        let enc = cb.makeComputeCommandEncoder()!
        for name in integrators[0].2 { s.encode(enc, makeKernel(libraries[p]![0], name)) }
        enc.endEncoding()
        commit(cb)
        let vGPU = s.mixedValues("velm", 4 * s.n)
        velocityByMode[p] = vGPU
        let posq = readBuffer(s.buffers["posq"]!, 4 * s.n, as: Float.self)
        let corr = readBuffer(s.buffers["posqCorrection"]!, 4 * s.n, as: Float.self)
        var errV = 0.0, maxV = 0.0, errP = 0.0, maxP = 0.0, diff = 0.0
        for i in 0..<s.n {
            let w = v[4 * i + 3]
            for d in 0..<3 {
                let vRef = v[4 * i + d] + 0.002 / 0x1p32 * Double(force[i + d * padded]) * w
                let pRef = Double(pos0[4 * i + d]) + vRef * 0.002
                let pGPU = p == .single ? Double(posq[4 * i + d]) : Double(posq[4 * i + d]) + Double(corr[4 * i + d])
                errV = max(errV, abs(vGPU[4 * i + d] - vRef))
                maxV = max(maxV, abs(vRef))
                errP = max(errP, abs(pGPU - pRef))
                maxP = max(maxP, abs(pRef))
                if p == .df64IEEE { diff = max(diff, abs(vGPU[4 * i + d] - velocityByMode[.df64Pairs]![4 * i + d])) }
            }
        }
        let diffText = p == .df64IEEE ? String(format: "%.2e", diff / maxV) : ""
        print("| \(p.label) | \(String(format: "%.2e", errV / maxV)) | \(String(format: "%.2e", errP / maxP)) | \(diffText) |")
    }
    print("")

    print("### Time per call, µs (GPU clock)")
    print("")
    print("Each cell is the median over \(timingRounds) rounds, with the interquartile range in brackets. A round measures every (variant, kernel) cell of one integrator and size once, as one command buffer of \(timingReps) repetitions, in a freshly shuffled order; one untimed round warms up first. Ratios are of medians, against float mixed.")
    print("")
    print("| Integrator | Kernel | Atoms | single | float mixed | df64 pairs | df64 IEEE | pairs / float mixed | IEEE / float mixed |")
    print("| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    var order = SplitMix64(state: 0x15_5800)
    var wholeVsSum = [String]()
    for atoms in [23_558, 173_112] {
        for (index, integrator) in integrators.enumerated() {
            let systems = Dictionary(uniqueKeysWithValues: Precision.allCases.map { ($0, System(n: atoms, precision: $0, seed: 0x15_5000)) })
            let kernels = Dictionary(uniqueKeysWithValues: Precision.allCases.map { p in (p, integrator.2.map { makeKernel(libraries[p]![index], $0) }) })
            let rows = integrator.2 + ["whole step"]
            var cells = [(Precision, Int)]()
            for p in Precision.allCases { for r in rows.indices { cells.append((p, r)) } }
            var samples = [String: [Double]]()
            for round in 0...timingRounds {
                for i in stride(from: cells.count - 1, to: 0, by: -1) { cells.swapAt(i, Int(order.next() % UInt64(i + 1))) }
                for (p, r) in cells {
                    let ks = r < integrator.2.count ? [kernels[p]![r]] : kernels[p]!
                    let t = systems[p]!.time(ks, reps: timingReps) * 1e6
                    if round > 0 { samples["\(p)/\(r)", default: []].append(t) }
                }
            }
            for (r, row) in rows.enumerated() {
                var med = [Precision: Double](), text = [Precision: String]()
                for p in Precision.allCases {
                    let v = samples["\(p)/\(r)"]!.sorted()
                    med[p] = median(v)
                    text[p] = String(format: "%.1f [%.1f-%.1f]", med[p]!, percentile(v, 0.25), percentile(v, 0.75))
                }
                let base = med[.floatMixed]!
                print("| \(integrator.0) | \(row) | \(atoms) | \(text[.single]!) | \(text[.floatMixed]!) | \(text[.df64Pairs]!) | \(text[.df64IEEE]!) | \(String(format: "%.2f", med[.df64Pairs]! / base)) | \(String(format: "%.2f", med[.df64IEEE]! / base)) |")
            }
            let ratios = Precision.allCases.map { p -> String in
                let parts = integrator.2.indices.map { median(samples["\(p)/\($0)"]!) }.reduce(0, +)
                return String(format: "%.2f", median(samples["\(p)/\(integrator.2.count)"]!) / parts)
            }
            wholeVsSum.append("| \(integrator.0) | \(atoms) | \(ratios.joined(separator: " | ")) |")
        }
    }
    print("")
    print("Whole step against the sum of its kernels timed alone (median / sum of medians). A kernel repeated alone rereads the same arrays; a ratio above 1 is consistent with more of them staying in the GPU caches than when the step's kernels alternate (cache residency is not measured here). The whole-step row is the figure to use.")
    print("")
    print("| Integrator | Atoms | single | float mixed | df64 pairs | df64 IEEE |")
    print("| --- | ---: | ---: | ---: | ---: | ---: |")
    wholeVsSum.forEach { print($0) }
    print("")

    // Cost of converting a velocity-sized array when device memory holds pairs.
    let lib = makeLibrary(stdHeader + df64Source + convertSource)
    let from = makePipeline(lib, "df64FromIEEE"), to = makePipeline(lib, "df64ToIEEE")
    print("### Bulk conversion of a velm-sized array (4 doubles per atom), µs (GPU clock)")
    print("")
    print("Median [interquartile range] of \(timingRounds) command buffers of \(timingReps) in-place conversions each, after one warm-up.")
    print("")
    print("| Atoms | Doubles | df64FromIEEE | df64ToIEEE |")
    print("| ---: | ---: | ---: | ---: |")
    for atoms in [23_558, 173_112] {
        let count = 4 * atoms
        var rng = SplitMix64(state: 0x15_6000)
        let buf = makeBuffer((0..<count).map { _ in rng.uniform(-3, 3).bitPattern })
        var results = [String]()
        for pso in [from, to] {
            var samples = [Double]()
            for trial in 0...timingRounds {
                let cb = queue.makeCommandBuffer()!
                let enc = cb.makeComputeCommandEncoder()!
                var c = UInt32(count)
                for _ in 0..<timingReps {
                    enc.setComputePipelineState(pso)
                    enc.setBuffer(buf, offset: 0, index: 0)
                    enc.setBytes(&c, length: 4, index: 1)
                    enc.dispatchThreads(MTLSize(width: count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
                }
                enc.endEncoding()
                commit(cb)
                if trial > 0 { samples.append((cb.gpuEndTime - cb.gpuStartTime) / Double(timingReps) * 1e6) }
            }
            samples.sort()
            results.append(String(format: "%.1f [%.1f-%.1f]", median(samples), percentile(samples, 0.25), percentile(samples, 0.75)))
        }
        print("| \(atoms) | \(count) | \(results[0]) | \(results[1]) |")
    }
    print("")
    let after = busyProcesses()
    print("Build processes after timing: \(after.isEmpty ? "none" : after). Timing is \(before.isEmpty && after.isEmpty ? "uncontended" : "CONTENDED, rerun")." )
    print("")
}

// MARK: - Main

switch section {
case "accuracy": runAccuracy()
case "convert": runConvert()
case "census": runCensus()
case "timing": runTiming()
case "all":
    runAccuracy()
    runConvert()
    runCensus()
    runTiming()
default:
    fputs("unknown section \(section)\n", stderr)
    exit(1)
}

// verify-e4: independent probe of float -> integer conversions on the GPU.
import Metal
import Foundation

let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
func file(_ n: String) -> String { try! String(contentsOfFile: dir + "/" + n, encoding: .utf8) }

let singleDefs = """
typedef float real;
typedef float2 real2;
typedef float3 real3;
typedef float4 real4;
typedef float mixed;
typedef float2 mixed2;
typedef float3 mixed3;
typedef float4 mixed4;
#define make_real2 make_float2
#define make_real3 make_float3
#define make_real4 make_float4
#define make_mixed2 make_float2
#define make_mixed3 make_float3
#define make_mixed4 make_float4
"""
let mixedDefs = """
typedef float real;
typedef float2 real2;
typedef float3 real3;
typedef float4 real4;
typedef df64 mixed;
typedef df64_2 mixed2;
typedef df64_3 mixed3;
typedef df64_4 mixed4;
#define make_real2 make_float2
#define make_real3 make_float3
#define make_real4 make_float4
#define make_mixed2 df64_2
#define make_mixed3 df64_3
#define make_mixed4 df64_4
#define double df64
#define double2 df64_2
#define double3 df64_3
#define double4 df64_4
#define make_double2 df64_2
#define make_double3 df64_3
#define make_double4 df64_4
"""

// My own kernel. Column 4 is whatever realToFixedPoint the prelude defines (or the bare copy).
let kernelSrc = """
inline long proposedFix(float x) {
    float v = x*0x1p32f;
    return v < -0x1p63f ? LONG_MIN : v >= 0x1p63f ? LONG_MAX : (long) v;
}
kernel void probe(device const float* in [[buffer(0)]], device ulong* out [[buffer(1)]], uint i [[thread_position_in_grid]]) {
    float v = in[i];
    out[8*i+0] = (ulong) (long) v;
    out[8*i+1] = (ulong) v;
    out[8*i+2] = (ulong) (uint) (int) v;
    out[8*i+3] = (ulong) (uint) v;
    out[8*i+4] = (ulong) realToFixedPoint(v);
    out[8*i+5] = (ulong) proposedFix(v);
    mixed m = v;
    out[8*i+6] = (ulong) realToFixedPoint(m);
    out[8*i+7] = (ulong) (long) m;
}
"""
let bareRtfp = """
typedef float real;
typedef float mixed;
inline long realToFixedPoint(real x) {
    return (long) (x*0x100000000);
}
"""
let head = "#include <metal_stdlib>\nusing namespace metal;\n"
func prelude(mixed: Bool, common: String) -> String {
    // Same order as MetalContext::createLibrary.
    var s = head
    if mixed { s += "#define USE_MIXED_PRECISION 1\n#define SUPPORTS_DOUBLE_PRECISION\n" + file("df64.metal") + "\n" + mixedDefs + "\n" }
    else { s += singleDefs + "\n" }
    s += "typedef unsigned int tileflags;\n" + file(common) + "\n"
    return s
}

let p31: Float = 2147483648.0, p63: Float = 9223372036854775808.0
let inputs: [(String, Float)] = [
    ("0", 0), ("-0", -0.0), ("1", 1), ("-1", -1), ("0.75", 0.75), ("-2.5", -2.5), ("1e5", 1e5), ("-123456.5", -123456.5),
    ("2^30", 1073741824), ("2^31-128", 2147483520), ("-(2^31-128)", -2147483520),
    ("2^31", p31), ("-2^31", -p31), ("-(2^31+256)", -2147483904), ("4e9", 4e9), ("1e10", 1e10), ("-1e10", -1e10),
    ("2^55", 36028797018963968), ("4.6e18", 4.6e18), ("2^62", 4611686018427387904), ("2^63-2^39", 9223371487098961920),
    ("2^63", p63), ("-2^63", -p63), ("2^64", 18446744073709551616), ("1e19", 1e19), ("-1e20", -1e20),
    ("1e22", 1e22), ("2.1837e22", 2.1837e22), ("2e22", 2e22), ("-3.877e26", -3.877e26), ("4e26", 4e26),
    ("1e22*2^32", 1e22 * 4294967296), ("FLT_MAX", .greatestFiniteMagnitude), ("-FLT_MAX", -.greatestFiniteMagnitude),
    ("+inf", .infinity), ("-inf", -.infinity), ("NaN", .nan), ("-NaN", -Float.nan),
]

// Host references. wrap = exact truncated value mod 2^N; sat = clamp to the type's range.
func truncMod64(_ v: Float) -> UInt64? {
    if !v.isFinite { return nil }
    let t = v.rounded(.towardZero), mag = t.magnitude
    var low: UInt64
    if mag < 18446744073709551616 { low = UInt64(mag) }
    else { let e = Int(mag.exponent) - 23; low = e >= 64 ? 0 : UInt64(mag.significandBitPattern | (1 << 23)) << UInt64(e) }
    return t < 0 ? 0 &- low : low
}
func satS(_ v: Float, _ bits: Int) -> UInt64? {
    if v.isNaN { return nil }
    let lim = Float(sign: .plus, exponent: bits - 1, significand: 1)
    let mask: UInt64 = bits == 64 ? ~0 : (1 << UInt64(bits)) - 1
    if v >= lim { return (UInt64(1) << UInt64(bits - 1)) - 1 }
    if v < -lim { return (UInt64(1) << UInt64(bits - 1)) }
    return UInt64(bitPattern: Int64(v.rounded(.towardZero))) & mask
}
func satU(_ v: Float, _ bits: Int) -> UInt64? {
    if v.isNaN { return nil }
    let lim = Float(sign: .plus, exponent: bits, significand: 1)
    if v >= lim { return bits == 64 ? ~0 : (1 << UInt64(bits)) - 1 }
    if v <= -1 { return 0 }
    return UInt64(v.rounded(.towardZero).magnitude)
}
func label(_ got: UInt64, sat: UInt64?, wrap: UInt64?) -> String {
    switch (got == sat, got == wrap) {
    case (true, true): return "="
    case (true, false): return "S"
    case (false, true): return "W"
    default: return "?"
    }
}

let dev = MTLCreateSystemDefaultDevice()!
print("device \(dev.name)  os \(ProcessInfo.processInfo.operatingSystemVersionString)")
let queue = dev.makeCommandQueue()!
let n = inputs.count
let inBuf = dev.makeBuffer(bytes: inputs.map { $0.1 }, length: 4 * n)!
let outBuf = dev.makeBuffer(length: 64 * n)!

func run(_ name: String, _ src: String, fast: Bool) -> [UInt64]? {
    let opt = MTLCompileOptions()
    opt.languageVersion = .version3_1
    opt.mathMode = fast ? .fast : .safe
    opt.mathFloatingPointFunctions = .precise
    let lib: MTLLibrary
    do { lib = try dev.makeLibrary(source: src, options: opt) }
    catch { print("[\(name)] COMPILE FAILED: \(error)"); return nil }
    let pso = try! dev.makeComputePipelineState(function: lib.makeFunction(name: "probe")!)
    memset(outBuf.contents(), 0xAB, 64 * n)
    let cb = queue.makeCommandBuffer()!, enc = cb.makeComputeCommandEncoder()!
    enc.setComputePipelineState(pso); enc.setBuffer(inBuf, offset: 0, index: 0); enc.setBuffer(outBuf, offset: 0, index: 1)
    enc.dispatchThreads(MTLSize(width: n, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: n, height: 1, depth: 1))
    enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    if let e = cb.error { print("[\(name)] GPU error \(e)"); return nil }
    let p = outBuf.contents().bindMemory(to: UInt64.self, capacity: 8 * n)
    return (0..<8 * n).map { p[$0] }
}

let variants: [(String, String, Bool)] = [
    ("bare-safe", head + bareRtfp + kernelSrc, false),
    ("bare-fast", head + bareRtfp + kernelSrc, true),
    ("single-orig", prelude(mixed: false, common: "common-orig.metal") + kernelSrc, false),
    ("single-fixed", prelude(mixed: false, common: "common-fixed.metal") + kernelSrc, false),
    ("mixed-orig", prelude(mixed: true, common: "common-orig.metal") + kernelSrc, false),
    ("mixed-fixed", prelude(mixed: true, common: "common-fixed.metal") + kernelSrc, false),
    ("mixed-fixed-fast", prelude(mixed: true, common: "common-fixed.metal") + kernelSrc, true),
]
var results: [String: [UInt64]] = [:]
for (name, src, fast) in variants { if let r = run(name, src, fast: fast) { results[name] = r } }

func hx(_ v: UInt64, _ w: Int = 16) -> String { let s = String(v, radix: 16); return String(repeating: "0", count: max(0, w - s.count)) + s }
if let r = results["bare-safe"] {
    print("\nbare-safe. Labels: '=' in range/exact, S = saturated (not wrap), W = exact value mod 2^N (not sat), ? = neither")
    print(String(format: "%-12@ %-14@ | %-18@ %-18@ %-10@ %-10@ | %-18@ %-18@", "input", "x*2^32 (f32)", "(long)x", "(ulong)x", "(int)x", "(uint)x", "(long)(x*2^32)", "proposedFix(x)"))
    for (i, (name, v)) in inputs.enumerated() {
        let y = v * 4294967296
        let o = Array(r[8 * i..<8 * i + 8])
        let wrap32 = truncMod64(v).map { $0 & 0xffffffff }
        let c0 = hx(o[0]) + label(o[0], sat: satS(v, 64), wrap: truncMod64(v))
        let c1 = hx(o[1]) + label(o[1], sat: satU(v, 64), wrap: truncMod64(v))
        let c2 = hx(o[2], 8) + label(o[2], sat: satS(v, 32).map { $0 & 0xffffffff }, wrap: wrap32)
        let c3 = hx(o[3], 8) + label(o[3], sat: satU(v, 32), wrap: wrap32)
        let c4 = hx(o[4]) + label(o[4], sat: satS(y, 64), wrap: truncMod64(y))
        let c5 = hx(o[5]) + label(o[5], sat: satS(y, 64), wrap: truncMod64(y))
        print(String(format: "%-12@ %-14@ | %-18@ %-18@ %-10@ %-10@ | %-18@ %-18@", name, String(format: "%.6g", Double(y)), c0, c1, c2, c3, c4, c5))
    }
}
// Compare other variants to bare-safe, column by column.
let colNames = ["(long)x", "(ulong)x", "(int)x", "(uint)x", "realToFixedPoint(x)", "proposedFix(x)", "realToFixedPoint(mixed)", "(long)mixed"]
if let base = results["bare-safe"] {
    print("\nvariant vs bare-safe: per column, number of inputs that differ (and which)")
    for (name, _, _) in variants.dropFirst() {
        guard let r = results[name] else { continue }
        var parts: [String] = []
        for c in 0..<8 {
            // For *-fixed variants compare the prelude's realToFixedPoint to bare-safe proposedFix.
            let ref = (name.hasSuffix("fixed") || name.hasSuffix("fixed-fast")) && (c == 4 || c == 6) ? 5 : c
            let diffs = (0..<n).filter { r[8 * $0 + c] != base[8 * $0 + ref] }.map { inputs[$0].0 }
            parts.append("\(colNames[c])\(ref != c ? "~fix" : ""):\(diffs.count)\(diffs.isEmpty ? "" : "[" + diffs.joined(separator: ",") + "]")")
        }
        print("  \(name): " + parts.joined(separator: "  "))
    }
    // Explicit: proposedFix vs host saturating reference, every input.
    var bad: [String] = []
    for (i, (nm, v)) in inputs.enumerated() {
        let y = v * 4294967296
        let want = satS(y, 64) ?? 0   // NaN: want 0 (matches M2 today)
        if base[8 * i + 5] != want { bad.append("\(nm)->\(hx(base[8 * i + 5]))") }
    }
    print("\nproposedFix vs saturating reference (NaN expected 0): \(bad.isEmpty ? "all \(n) match" : "MISMATCH " + bad.joined(separator: " "))")
}

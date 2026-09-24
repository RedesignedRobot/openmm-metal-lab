// Runs `metal`'s fast-math accuracy probe on this GPU, then a denser sweep of the same functions.
// The probe tests 20 values from 1e-4 upward by factors of pi and uses a fast function only if its
// error is below 1e-6. usage: swiftc -O fastacc.swift -o fastacc && ./fastacc
import Metal
import Foundation
let src = """
#include <metal_stdlib>
using namespace metal;
kernel void probe(device float* v [[buffer(0)]], constant uint& n [[buffer(1)]], uint i [[thread_position_in_grid]]) {
    if (i >= n) return;
    float x = v[5*i];
    v[5*i+1] = fast::rsqrt(x);
    v[5*i+2] = fast::divide(1.0f, x);
    v[5*i+3] = fast::exp(x);
    v[5*i+4] = fast::log(x);
}
"""
let dev = MTLCreateSystemDefaultDevice()!
let opts = MTLCompileOptions()
opts.languageVersion = .version3_2
opts.mathMode = .safe
opts.mathFloatingPointFunctions = .precise
let lib = try! dev.makeLibrary(source: src, options: opts)
let pso = try! dev.makeComputePipelineState(function: lib.makeFunction(name: "probe")!)
let queue = dev.makeCommandQueue()!

func run(_ inputs: [Float]) -> [Float] {
    var n = UInt32(inputs.count)
    var data = [Float](repeating: 0, count: 5*inputs.count)
    for (i, x) in inputs.enumerated() { data[5*i] = x }
    let buf = dev.makeBuffer(bytes: data, length: 4*data.count, options: .storageModeShared)!
    let cb = queue.makeCommandBuffer()!
    let enc = cb.makeComputeCommandEncoder()!
    enc.setComputePipelineState(pso)
    enc.setBuffer(buf, offset: 0, index: 0)
    enc.setBytes(&n, length: 4, index: 1)
    enc.dispatchThreads(MTLSize(width: inputs.count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
    enc.endEncoding()
    cb.commit()
    cb.waitUntilCompleted()
    let p = buf.contents().bindMemory(to: Float.self, capacity: data.count)
    return Array(UnsafeBufferPointer(start: p, count: data.count))
}

func errors(_ inputs: [Float], expLimit: Double) -> [Double] {
    let r = run(inputs)
    var e = [0.0, 0.0, 0.0, 0.0]
    for i in 0..<inputs.count {
        let v = Double(r[5*i])
        e[0] = max(e[0], abs(1.0/v.squareRoot() - Double(r[5*i+1]))*v.squareRoot())
        e[1] = max(e[1], abs(1.0/v - Double(r[5*i+2]))/Double(r[5*i+2]))
        if v < expLimit { e[2] = max(e[2], abs(Foundation.exp(v) - Double(r[5*i+3]))/Double(r[5*i+3])) }
        e[3] = max(e[3], abs(Foundation.log(v) - Double(r[5*i+4]))/abs(Double(r[5*i+4])))
    }
    return e
}

var probe: [Float] = []
var next: Float = 1e-4
for _ in 0..<20 { probe.append(next); next *= Float.pi }
let names = ["rsqrt", "recip", "exp", "log"]
let p = errors(probe, expLimit: .infinity)
print("device \(dev.name)")
for k in 0..<4 { print("probe \(names[k]) max error \(p[k]) -> \(p[k] < 1e-6 ? "fast" : "precise")") }
var sweep: [Float] = []
for i in 0..<1_000_000 { sweep.append(Float(Foundation.pow(10.0, -4.0 + 8.0*Double(i)/1_000_000.0))) }
let s = errors(sweep.filter { abs($0 - 1) > 1e-3 }, expLimit: 80)
for k in 0..<4 { print("sweep 1e-4..1e4 \(names[k]) max relative error \(s[k])") }

// 028 nonbonded lane: compile saved kernel sources and print each kernel's pipeline limits.
// maxTotalThreadsPerThreadgroup drops below 1024 when a kernel needs more registers than a full group allows.
// usage: swift pipestat.swift <kernel> <file.metal>...
import Foundation
import Metal

let args = CommandLine.arguments
let kernel = args[1]
let device = MTLCreateSystemDefaultDevice()!
let options = MTLCompileOptions()
options.mathMode = .safe
options.languageVersion = .version3_2
options.mathFloatingPointFunctions = .precise
for path in args[2...] {
    let source = try! String(contentsOfFile: path, encoding: .utf8)
    do {
        let library = try device.makeLibrary(source: source, options: options)
        guard let function = library.makeFunction(name: kernel) else { continue }
        let pipeline = try device.makeComputePipelineState(function: function)
        print("\(path) \(kernel) maxThreads \(pipeline.maxTotalThreadsPerThreadgroup) width \(pipeline.threadExecutionWidth) tgmem \(pipeline.staticThreadgroupMemoryLength)")
    } catch {
        print("\(path) error \(error)")
    }
}

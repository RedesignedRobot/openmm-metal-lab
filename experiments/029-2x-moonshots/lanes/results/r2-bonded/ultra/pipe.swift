// Compiles a saved OpenMM Metal source with the platform's options and builds one pipeline, printing the error.
import Metal
import Foundation
let args = CommandLine.arguments
let source = try! String(contentsOfFile: args[1], encoding: .utf8)
let device = MTLCreateSystemDefaultDevice()!
let options = MTLCompileOptions()
options.languageVersion = .version3_2
options.mathMode = .safe
options.mathFloatingPointFunctions = .precise
do {
    let library = try device.makeLibrary(source: source, options: options)
    guard let function = library.makeFunction(name: args[2]) else { print("no function", args[2], library.functionNames); exit(1) }
    let pipeline = try device.makeComputePipelineState(function: function)
    print("ok maxThreads", pipeline.maxTotalThreadsPerThreadgroup, "static tg mem", pipeline.staticThreadgroupMemoryLength)
} catch {
    print("error:", error)
}

// Compile an MSL file with the options MetalContext uses and print each kernel's bindings.
// usage: mslc <file.metal> [3.1|3.2]
import Metal
import Foundation
let src = try! String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
let dev = MTLCreateSystemDefaultDevice()!
let opts = MTLCompileOptions()
opts.languageVersion = (CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "3.2") ? .version3_2 : .version3_1
opts.mathMode = .safe
opts.mathFloatingPointFunctions = .precise
do {
    let lib = try dev.makeLibrary(source: src, options: opts)
    for name in lib.functionNames.sorted() {
        let f = lib.makeFunction(name: name)!
        if f.functionType != .kernel { continue }
        var refl: MTLComputePipelineReflection?
        let pso = try dev.makeComputePipelineState(function: f, options: [.bindingInfo], reflection: &refl)
        print("kernel \(name) width=\(pso.threadExecutionWidth) maxThreads=\(pso.maxTotalThreadsPerThreadgroup)")
        for b in refl!.bindings {
            var size = ""
            if let bb = b as? MTLBufferBinding { size = " size=\(bb.bufferDataSize)" }
            print("  \(b.type == .buffer ? "buffer" : b.type == .threadgroupMemory ? "threadgroup" : "other") index=\(b.index) name=\(b.name) used=\(b.isUsed)\(size)")
        }
    }
    print("OK")
} catch { print("ERROR: \(error)") }

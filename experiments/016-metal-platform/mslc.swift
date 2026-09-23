import Foundation
import Metal
// usage: mslc file.metal [safe|relaxed|fast]
let dev = MTLCreateSystemDefaultDevice()!
let src = try! String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
let o = MTLCompileOptions()
o.languageVersion = .version3_1
let m = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "safe"
o.mathMode = m == "fast" ? .fast : (m == "relaxed" ? .relaxed : .safe)
do { let lib = try dev.makeLibrary(source: src, options: o); print("OK", lib.functionNames) }
catch { print("\(error)") }

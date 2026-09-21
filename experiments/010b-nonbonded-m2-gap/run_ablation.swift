import Foundation
import Metal
import OpenCL

struct Float4Param { var x: Float; var y: Float; var z: Float; var w: Float }

struct TimingStats: Codable {
    let median: Double
    let min: Double
    let max: Double
    let q1: Double
    let q3: Double
    let iqr: Double
    let mean: Double
    let stddev: Double
    let runs: [Double]

    init(runs: [Double]) {
        self.runs = runs
        let sorted = runs.sorted()
        let count = sorted.count
        self.min = sorted.first ?? 0.0
        self.max = sorted.last ?? 0.0

        if count == 0 {
            self.median = 0.0; self.q1 = 0.0; self.q3 = 0.0; self.iqr = 0.0
            self.mean = 0.0; self.stddev = 0.0
            return
        }

        func percentile(_ p: Double) -> Double {
            let idx = p * Double(count - 1)
            let lo = Int(floor(idx))
            let hi = Int(ceil(idx))
            let w = idx - Double(lo)
            return lo == hi ? sorted[lo] : (1.0 - w) * sorted[lo] + w * sorted[hi]
        }

        self.median = percentile(0.5)
        self.q1 = percentile(0.25)
        self.q3 = percentile(0.75)
        self.iqr = self.q3 - self.q1
        let sum = sorted.reduce(0.0, +)
        let meanVal = sum / Double(count)
        self.mean = meanVal
        let variance = sorted.reduce(0.0) { $0 + ($1 - meanVal) * ($1 - meanVal) } / Double(count)
        self.stddev = sqrt(variance)
    }
}

class AblationSuite {
    let name: String
    let isPME: Bool
    let capDir: String

    let meta: [String: Any]
    let numAtoms: Int
    let numBlocks: Int
    var maxTiles: UInt32
    var startTileIndex: UInt32 = 0
    var numTileIndices: UInt64

    var pBox: Float4Param
    var invBox: Float4Param
    var pVecX: Float4Param
    var pVecY: Float4Param
    var pVecZ: Float4Param

    let fbBeforeData: Data
    let posqData: Data
    let exclData: Data
    let exclTilesData: Data
    let tilesData: Data
    let countData: Data
    let centerData: Data
    let sizeData: Data
    let atomsData: Data
    let paramsData: Data

    let dev: MTLDevice
    let queue: MTLCommandQueue

    var clPlatform: cl_platform_id?
    var clDevice: cl_device_id?
    var clContext: cl_context?
    var clQueue: cl_command_queue?

    init(name: String) {
        self.name = name
        self.isPME = (name == "apoa1pme")
        let path = "/tmp/openmm_010_captures/\(name)"
        self.capDir = path

        let metaUrl = URL(fileURLWithPath: "\(path)/metadata.json")
        let metaData = try! Data(contentsOf: metaUrl)
        self.meta = try! JSONSerialization.jsonObject(with: metaData) as! [String: Any]

        self.numAtoms = self.meta["numAtoms"] as! Int
        self.numBlocks = self.meta["numBlocks"] as! Int
        self.maxTiles = UInt32(self.meta["maxTiles"] as! Int)
        self.numTileIndices = UInt64(self.meta["numTiles"] as! Int)

        let boxArr = self.meta["periodicBoxSize"] as! [Double]
        let invBoxArr = self.meta["invPeriodicBoxSize"] as! [Double]
        let vecXArr = self.meta["periodicBoxVecX"] as! [Double]
        let vecYArr = self.meta["periodicBoxVecY"] as! [Double]
        let vecZArr = self.meta["periodicBoxVecZ"] as! [Double]

        self.pBox = Float4Param(x: Float(boxArr[0]), y: Float(boxArr[1]), z: Float(boxArr[2]), w: Float(boxArr[3]))
        self.invBox = Float4Param(x: Float(invBoxArr[0]), y: Float(invBoxArr[1]), z: Float(invBoxArr[2]), w: Float(invBoxArr[3]))
        self.pVecX = Float4Param(x: Float(vecXArr[0]), y: Float(vecXArr[1]), z: Float(vecXArr[2]), w: Float(vecXArr[3]))
        self.pVecY = Float4Param(x: Float(vecYArr[0]), y: Float(vecYArr[1]), z: Float(vecYArr[2]), w: Float(vecYArr[3]))
        self.pVecZ = Float4Param(x: Float(vecZArr[0]), y: Float(vecZArr[1]), z: Float(vecZArr[2]), w: Float(vecZArr[3]))

        let loadData = { (fn: String) -> Data in
            return try! Data(contentsOf: URL(fileURLWithPath: "\(path)/\(fn)"))
        }

        self.fbBeforeData = loadData("forceBuffers_before.bin")
        self.posqData = loadData("posq.bin")
        self.exclData = loadData("exclusions.bin")
        self.exclTilesData = loadData("exclusionTiles.bin")
        self.tilesData = loadData("interactingTiles_after_findBlocksWithInteractions.bin")
        self.countData = loadData("interactionCount_after_findBlocksWithInteractions.bin")
        self.centerData = loadData("blockCenter_after_findBlockBounds.bin")
        self.sizeData = loadData("blockBoundingBox_after_findBlockBounds.bin")
        self.atomsData = loadData("interactingAtoms_after_findBlocksWithInteractions.bin")
        self.paramsData = loadData("param_0_nonbonded2_sigmaEpsilon.bin")

        self.dev = MTLCreateSystemDefaultDevice()!
        self.queue = self.dev.makeCommandQueue()!

        var err: cl_int = 0
        clGetPlatformIDs(1, &self.clPlatform, nil)
        clGetDeviceIDs(self.clPlatform, cl_device_type(CL_DEVICE_TYPE_GPU), 1, &self.clDevice, nil)
        self.clContext = clCreateContext(nil, 1, &self.clDevice, nil, nil, &err)
        self.clQueue = clCreateCommandQueue(self.clContext, self.clDevice, cl_command_queue_properties(CL_QUEUE_PROFILING_ENABLE), &err)
    }

    func makeMtlBuf(_ data: Data) -> MTLBuffer {
        return data.withUnsafeBytes { ptr in
            self.dev.makeBuffer(bytes: ptr.baseAddress!, length: data.count, options: .storageModeShared)!
        }
    }

    func timeOpenCL(kernel: cl_kernel, repeats: Int = 20) -> TimingStats {
        func makeClBuf(_ data: Data, readOnly: Bool = true) -> cl_mem {
            var err: cl_int = 0
            let flags = readOnly ? (CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR) : (CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR)
            return data.withUnsafeBytes { ptr in
                clCreateBuffer(self.clContext, cl_mem_flags(flags), data.count, UnsafeMutableRawPointer(mutating: ptr.baseAddress), &err)
            }
        }
        var bufClFB = makeClBuf(self.fbBeforeData, readOnly: false)
        var zeroEnergy = [Float](repeating: 0.0, count: 15360)
        var err: cl_int = 0
        var bufClEB = clCreateBuffer(self.clContext, cl_mem_flags(CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR), 15360 * 4, &zeroEnergy, &err)
        var bufClPosq = makeClBuf(self.posqData)
        var bufClExcl = makeClBuf(self.exclData)
        var bufClExclTiles = makeClBuf(self.exclTilesData)
        var bufClTiles = makeClBuf(self.tilesData)
        var bufClCount = makeClBuf(self.countData)
        var bufClCenter = makeClBuf(self.centerData)
        var bufClSize = makeClBuf(self.sizeData)
        var bufClAtoms = makeClBuf(self.atomsData)
        var bufClParams = makeClBuf(self.paramsData)

        clSetKernelArg(kernel, 0, MemoryLayout<cl_mem>.size, &bufClFB)
        clSetKernelArg(kernel, 1, MemoryLayout<cl_mem>.size, &bufClEB)
        clSetKernelArg(kernel, 2, MemoryLayout<cl_mem>.size, &bufClPosq)
        clSetKernelArg(kernel, 3, MemoryLayout<cl_mem>.size, &bufClExcl)
        clSetKernelArg(kernel, 4, MemoryLayout<cl_mem>.size, &bufClExclTiles)
        clSetKernelArg(kernel, 5, MemoryLayout<cl_uint>.size, &self.startTileIndex)
        clSetKernelArg(kernel, 6, MemoryLayout<cl_ulong>.size, &self.numTileIndices)
        clSetKernelArg(kernel, 7, MemoryLayout<cl_mem>.size, &bufClTiles)
        clSetKernelArg(kernel, 8, MemoryLayout<cl_mem>.size, &bufClCount)
        clSetKernelArg(kernel, 9, MemoryLayout<Float4Param>.size, &self.pBox)
        clSetKernelArg(kernel, 10, MemoryLayout<Float4Param>.size, &self.invBox)
        clSetKernelArg(kernel, 11, MemoryLayout<Float4Param>.size, &self.pVecX)
        clSetKernelArg(kernel, 12, MemoryLayout<Float4Param>.size, &self.pVecY)
        clSetKernelArg(kernel, 13, MemoryLayout<Float4Param>.size, &self.pVecZ)
        clSetKernelArg(kernel, 14, MemoryLayout<cl_uint>.size, &self.maxTiles)
        clSetKernelArg(kernel, 15, MemoryLayout<cl_mem>.size, &bufClCenter)
        clSetKernelArg(kernel, 16, MemoryLayout<cl_mem>.size, &bufClSize)
        clSetKernelArg(kernel, 17, MemoryLayout<cl_mem>.size, &bufClAtoms)
        clSetKernelArg(kernel, 18, MemoryLayout<cl_mem>.size, &bufClParams)

        var gWork: size_t = 60 * 256
        var lWork: size_t = 256

        // Warmup: restore buffer each time and wait for GPU frequency ramp
        for _ in 0..<5 {
            _ = self.fbBeforeData.withUnsafeBytes { ptr in
                clEnqueueWriteBuffer(self.clQueue, bufClFB, cl_bool(CL_TRUE), 0, self.fbBeforeData.count, ptr.baseAddress!, 0, nil, nil)
            }
            var ev: cl_event?
            clEnqueueNDRangeKernel(self.clQueue, kernel, 1, nil, &gWork, &lWork, 0, nil, &ev)
            clFinish(self.clQueue)
            clReleaseEvent(ev)
        }

        var runs: [Double] = []
        for _ in 0..<repeats {
            _ = self.fbBeforeData.withUnsafeBytes { ptr in
                clEnqueueWriteBuffer(self.clQueue, bufClFB, cl_bool(CL_TRUE), 0, self.fbBeforeData.count, ptr.baseAddress!, 0, nil, nil)
            }
            var ev: cl_event?
            clEnqueueNDRangeKernel(self.clQueue, kernel, 1, nil, &gWork, &lWork, 0, nil, &ev)
            clFinish(self.clQueue)
            var start: cl_ulong = 0
            var end: cl_ulong = 0
            clGetEventProfilingInfo(ev, cl_profiling_info(CL_PROFILING_COMMAND_START), MemoryLayout<cl_ulong>.size, &start, nil)
            clGetEventProfilingInfo(ev, cl_profiling_info(CL_PROFILING_COMMAND_END), MemoryLayout<cl_ulong>.size, &end, nil)
            let ms = Double(end - start) * (125.0 / 3.0) / 1e6
            runs.append(ms)
            clReleaseEvent(ev)
        }
        return TimingStats(runs: runs)
    }

    func timeMetal(pso: MTLComputePipelineState, groupSize: Int, repeats: Int = 20, useTG: Bool = true) -> TimingStats {
        let bufFB = makeMtlBuf(self.fbBeforeData)
        var zeroEnergy = [Float](repeating: 0.0, count: 15360)
        let bufEB = self.dev.makeBuffer(bytes: &zeroEnergy, length: 15360 * 4, options: .storageModeShared)!
        let bufPosq = makeMtlBuf(self.posqData)
        let bufExcl = makeMtlBuf(self.exclData)
        let bufExclTiles = makeMtlBuf(self.exclTilesData)
        let bufTiles = makeMtlBuf(self.tilesData)
        let bufCount = makeMtlBuf(self.countData)
        let bufCenter = makeMtlBuf(self.centerData)
        let bufSize = makeMtlBuf(self.sizeData)
        let bufAtoms = makeMtlBuf(self.atomsData)
        let bufParams = makeMtlBuf(self.paramsData)

        // Warmup: restore buffer each time and wait for GPU frequency ramp
        for _ in 0..<5 {
            _ = self.fbBeforeData.withUnsafeBytes { ptr in
                memcpy(bufFB.contents(), ptr.baseAddress!, self.fbBeforeData.count)
            }
            let cmd = self.queue.makeCommandBuffer()!
            let enc = cmd.makeComputeCommandEncoder()!
            enc.setComputePipelineState(pso)
            enc.setBuffer(bufFB, offset: 0, index: 0)
            enc.setBuffer(bufEB, offset: 0, index: 1)
            enc.setBuffer(bufPosq, offset: 0, index: 2)
            enc.setBuffer(bufExcl, offset: 0, index: 3)
            enc.setBuffer(bufExclTiles, offset: 0, index: 4)
            enc.setBytes(&self.startTileIndex, length: 4, index: 5)
            enc.setBytes(&self.numTileIndices, length: 8, index: 6)
            enc.setBuffer(bufTiles, offset: 0, index: 7)
            enc.setBuffer(bufCount, offset: 0, index: 8)
            enc.setBytes(&self.pBox, length: 16, index: 9)
            enc.setBytes(&self.invBox, length: 16, index: 10)
            enc.setBytes(&self.pVecX, length: 16, index: 11)
            enc.setBytes(&self.pVecY, length: 16, index: 12)
            enc.setBytes(&self.pVecZ, length: 16, index: 13)
            enc.setBytes(&self.maxTiles, length: 4, index: 14)
            enc.setBuffer(bufCenter, offset: 0, index: 15)
            enc.setBuffer(bufSize, offset: 0, index: 16)
            enc.setBuffer(bufAtoms, offset: 0, index: 17)
            enc.setBuffer(bufParams, offset: 0, index: 18)
            if useTG {
                let numGroups = (60 * 256) / groupSize
                enc.dispatchThreadgroups(MTLSize(width: numGroups, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: groupSize, height: 1, depth: 1))
            } else {
                enc.dispatchThreads(MTLSize(width: 60 * 256, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: groupSize, height: 1, depth: 1))
            }
            enc.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
        }

        var runs: [Double] = []
        for _ in 0..<repeats {
            _ = self.fbBeforeData.withUnsafeBytes { ptr in
                memcpy(bufFB.contents(), ptr.baseAddress!, self.fbBeforeData.count)
            }
            let cmd = self.queue.makeCommandBuffer()!
            let enc = cmd.makeComputeCommandEncoder()!
            enc.setComputePipelineState(pso)
            enc.setBuffer(bufFB, offset: 0, index: 0)
            enc.setBuffer(bufEB, offset: 0, index: 1)
            enc.setBuffer(bufPosq, offset: 0, index: 2)
            enc.setBuffer(bufExcl, offset: 0, index: 3)
            enc.setBuffer(bufExclTiles, offset: 0, index: 4)
            enc.setBytes(&self.startTileIndex, length: 4, index: 5)
            enc.setBytes(&self.numTileIndices, length: 8, index: 6)
            enc.setBuffer(bufTiles, offset: 0, index: 7)
            enc.setBuffer(bufCount, offset: 0, index: 8)
            enc.setBytes(&self.pBox, length: 16, index: 9)
            enc.setBytes(&self.invBox, length: 16, index: 10)
            enc.setBytes(&self.pVecX, length: 16, index: 11)
            enc.setBytes(&self.pVecY, length: 16, index: 12)
            enc.setBytes(&self.pVecZ, length: 16, index: 13)
            enc.setBytes(&self.maxTiles, length: 4, index: 14)
            enc.setBuffer(bufCenter, offset: 0, index: 15)
            enc.setBuffer(bufSize, offset: 0, index: 16)
            enc.setBuffer(bufAtoms, offset: 0, index: 17)
            enc.setBuffer(bufParams, offset: 0, index: 18)

            if useTG {
                let numGroups = (60 * 256) / groupSize
                enc.dispatchThreadgroups(MTLSize(width: numGroups, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: groupSize, height: 1, depth: 1))
            } else {
                enc.dispatchThreads(MTLSize(width: 60 * 256, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: groupSize, height: 1, depth: 1))
            }
            enc.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()

            let ms = (cmd.gpuEndTime - cmd.gpuStartTime) * 1000.0
            runs.append(ms)
        }
        return TimingStats(runs: runs)
    }

    func buildClKernel(extraDefs: [String] = []) -> cl_kernel {
        let prefix = self.isPME ? "computeNonbonded_pme" : "computeNonbonded_rf"
        let clSrc = try! String(contentsOfFile: "kernels/\(prefix).full.cl", encoding: .utf8)
        var cStr: UnsafePointer<CChar>? = (clSrc as NSString).utf8String
        var err: cl_int = 0
        let prog = clCreateProgramWithSource(self.clContext, 1, &cStr, nil, &err)
        let defsStr = extraDefs.map { "-D\($0)=1" }.joined(separator: " ")
        let berr = clBuildProgram(prog, 1, &self.clDevice, "-cl-mad-enable -cl-no-signed-zeros \(defsStr)", nil, nil)
        if berr != 0 {
            var logSize: size_t = 0
            clGetProgramBuildInfo(prog, self.clDevice!, cl_program_build_info(CL_PROGRAM_BUILD_LOG), 0, nil, &logSize)
            var logBuf = [CChar](repeating: 0, count: logSize)
            clGetProgramBuildInfo(prog, self.clDevice!, cl_program_build_info(CL_PROGRAM_BUILD_LOG), logSize, &logBuf, nil)
            print("OpenCL build error (\(defsStr)): \(String(cString: logBuf))")
        }
        let k = clCreateKernel(prog, "computeNonbonded", &err)
        if k == nil {
            print("Failed to create OpenCL kernel: err = \(err)")
            exit(1)
        }
        return k!
    }

    func buildMtlTrans(extraDefs: [String] = []) -> MTLComputePipelineState {
        let prelude = try! String(contentsOfFile: "kernels/prelude.metal", encoding: .utf8)
        let prefix = self.isPME ? "computeNonbonded_pme" : "computeNonbonded_rf"
        let body = try! String(contentsOfFile: "kernels/\(prefix).body.cl", encoding: .utf8)
        let defs = try! String(contentsOfFile: "kernels/\(prefix).defines", encoding: .utf8)

        var progDefs = ""
        for line in defs.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: "\t")
            if parts.count >= 3 && parts[0] == "program" {
                progDefs += "#define \(parts[1]) \(parts[2])\n"
            }
        }
        for d in extraDefs {
            progDefs += "#define \(d) 1\n"
        }

        func rewriteKernelSignatures(source: String) -> String {
            let pattern = #"(?:KERNEL|__kernel)\s+void\s+(\w+)\s*\(([\s\S]*?)\)\s*\{"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return source }
            var result = ""
            var lastIndex = source.startIndex
            let nsSource = source as NSString
            let matches = regex.matches(in: source, options: [], range: NSRange(location: 0, length: nsSource.length))
            for match in matches {
                let matchRange = Range(match.range, in: source)!
                result.append(contentsOf: source[lastIndex..<matchRange.lowerBound])
                let kernelName = nsSource.substring(with: match.range(at: 1))
                let rawParams = nsSource.substring(with: match.range(at: 2))
                let lines = rawParams.components(separatedBy: "\n")
                var rewrittenLines: [String] = []
                var localCopies: [String] = []
                for line in lines {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("#") {
                        rewrittenLines.append(line)
                        localCopies.append(line)
                        continue
                    }
                    let parts = line.components(separatedBy: ",")
                    var newParts: [String] = []
                    for part in parts {
                        let pTrimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
                        if pTrimmed.isEmpty {
                            newParts.append(part)
                            continue
                        }
                        if pTrimmed.contains("*") || pTrimmed.contains("PARAMETER_ARGUMENTS") || pTrimmed.contains("EXTRA_ARGS") {
                            newParts.append(part)
                        } else {
                            var words = pTrimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                            if words.count >= 2 {
                                let paramName = words.removeLast()
                                let paramType = words.joined(separator: " ")
                                let nonConstType = words.filter { $0 != "const" }.joined(separator: " ")
                                let leadingWs = part.prefix(while: { $0.isWhitespace })
                                newParts.append("\(leadingWs)constant \(paramType)& _in_\(paramName)")
                                localCopies.append("\(nonConstType) \(paramName) = _in_\(paramName);")
                            } else {
                                newParts.append(part)
                            }
                        }
                    }
                    rewrittenLines.append(newParts.joined(separator: ","))
                }
                let newParamsStr = rewrittenLines.joined(separator: "\n")
                var copiesStr = ""
                if !localCopies.isEmpty {
                    copiesStr = "\n    " + localCopies.joined(separator: "\n    ")
                }
                result.append("kernel void \(kernelName)(\(newParamsStr)) {\(copiesStr)")
                lastIndex = matchRange.upperBound
            }
            result.append(contentsOf: source[lastIndex...])
            return result
        }

        func rewriteVectorLiterals(source: String) -> String {
            let pattern = #"\(\s*(real4|float8|float4|float2|float3|int2|int3|int4|uint2|uint3|uint4|short2|short3|short4)\s*\)\s*\("#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return source }
            return regex.stringByReplacingMatches(in: source, options: [], range: NSRange(location: 0, length: (source as NSString).length), withTemplate: "$1(")
        }

        var fullTrans = prelude + "\n" + progDefs + "\n" + body
        fullTrans = rewriteKernelSignatures(source: fullTrans)
        fullTrans = rewriteVectorLiterals(source: fullTrans)

        let opt = MTLCompileOptions()
        opt.mathMode = .safe
        opt.languageVersion = .version3_1
        let lib = try! self.dev.makeLibrary(source: fullTrans, options: opt)
        let fn = lib.makeFunction(name: "computeNonbonded")!
        return try! self.dev.makeComputePipelineState(function: fn)
    }

    func buildMtlNative(extraMacros: [String: NSObject] = [:]) -> MTLComputePipelineState {
        let nativeSrc = try! String(contentsOfFile: "kernels/computeNonbonded_native.metal", encoding: .utf8)
        let opt = MTLCompileOptions()
        opt.languageVersion = .version3_1
        var macros: [String: NSObject] = [
            "ENABLE_FORCE_ACCUMULATION": NSNumber(value: 1),
            "ENABLE_OPTIMIZED": NSNumber(value: 1)
        ]
        if self.isPME {
            macros["USE_PME"] = NSNumber(value: 1)
        }
        for (k, v) in extraMacros {
            macros[k] = v
        }
        opt.preprocessorMacros = macros
        do {
            let lib = try self.dev.makeLibrary(source: nativeSrc, options: opt)
            guard let fn = lib.makeFunction(name: "computeNonbonded") else {
                print("Failed to find computeNonbonded in Metal lib")
                exit(1)
            }
            return try self.dev.makeComputePipelineState(function: fn)
        } catch {
            print("Metal build error (\(extraMacros)): \(error)")
            exit(1)
        }
    }
}

func pad(_ s: String, _ w: Int, right: Bool = false) -> String {
    if s.count >= w { return s }
    let p = String(repeating: " ", count: w - s.count)
    return right ? p + s : s + p
}

print("STARTING COMPREHENSIVE ABLATION SUITE")
let numRepeats = 20

for bench in ["apoa1rf", "apoa1pme"] {
    print("\n==========================================================================================")
    print("Ablation Matrix: \(bench)")
    print("==========================================================================================")
    let suite = AblationSuite(name: bench)

    let ablations: [(id: String, desc: String, defs: [String])] = [
        ("baseline_no_energy", "Baseline (forces only, no energy)", []),
        ("baseline_with_energy", "Baseline (with energy)", ["INCLUDE_ENERGY"]),
        ("ablation_a_no_atomic", "(a) Force writeback: non-atomic store into private slot", ["ABLATION_A_NO_ATOMIC"]),
        ("ablation_b_no_fixed_point", "(b) Fixed-point removed: direct float cast", ["ABLATION_B_NO_FIXED_POINT"]),
        ("ablation_c_no_exclusions", "(c) Exclusions removed: skip loop 1", ["ABLATION_C_NO_EXCLUSIONS"]),
        ("ablation_e_memory_only", "(e) Arithmetic stubbed: memory pattern preserved", ["ABLATION_E_MEMORY_ONLY"]),
        ("ablation_f_arithmetic_only", "(f) Memory stubbed: arithmetic executed", ["ABLATION_F_ARITHMETIC_ONLY"])
    ]

    print("\(pad("Ablation Case", 26)) | \(pad("OpenCL", 13)) | \(pad("Mtl Trans(256)", 15)) | \(pad("Mtl Nat(256)", 13)) | \(pad("Mtl Nat(32)", 13)) | \(pad("Gap (Nat32-CL)", 15))")
    print("----------------------------------------------------------------------------------------------------------------")

    for ab in ablations {
        let clK = suite.buildClKernel(extraDefs: ab.defs)
        let clStats = suite.timeOpenCL(kernel: clK, repeats: numRepeats)

        var transStatsStr = "N/A"
        // Metal translation supports baseline, A, B, C
        if ab.id != "ablation_e_memory_only" && ab.id != "ablation_f_arithmetic_only" {
            let transPso = suite.buildMtlTrans(extraDefs: ab.defs)
            let transStats = suite.timeMetal(pso: transPso, groupSize: 256, repeats: numRepeats, useTG: true)
            transStatsStr = String(format: "%.4f ms", transStats.median)
        }

        var mtlMacros: [String: NSObject] = [:]
        for d in ab.defs {
            mtlMacros[d] = NSNumber(value: 1)
        }
        let mtlPso = suite.buildMtlNative(extraMacros: mtlMacros)
        let nat256Stats = suite.timeMetal(pso: mtlPso, groupSize: 256, repeats: numRepeats, useTG: true)
        let nat32Stats = suite.timeMetal(pso: mtlPso, groupSize: 32, repeats: numRepeats, useTG: true)

        let gap = nat32Stats.median - clStats.median
        let gapStr = String(format: "%+.4f ms", gap)

        print("\(pad(ab.id, 26)) | \(pad(String(format: "%.4f ms", clStats.median), 13)) | \(pad(transStatsStr, 15)) | \(pad(String(format: "%.4f ms", nat256Stats.median), 13)) | \(pad(String(format: "%.4f ms", nat32Stats.median), 13)) | \(pad(gapStr, 15))")
    }
}

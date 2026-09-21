import Foundation
import Metal
import OpenCL
import Darwin

// MARK: - Data Models

struct Float4Param { var x: Float; var y: Float; var z: Float; var w: Float }

struct AgreementStats: Codable {
    let maxDiffFixedPoint: Int64
    let maxAbsForceDiff: Double
    let forcePpm: Double
    let exactMatches: Int
    let totalWords: Int
    let energyDiff: Double
    let energyPpm: Double
    let passed: Bool
}

struct MutationGateResult: Codable {
    let mutation: String
    let targetPpm: Double
    let gateDetected: Bool
}

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

struct AblationRow: Codable {
    let id: String
    let description: String
    let opencl: TimingStats
    let metalTranslation: TimingStats?
    let metalNative256: TimingStats
    let metalNative32: TimingStats
    let gapNat32VsCl: Double
}

struct BenchmarkCaseResult: Codable {
    let numAtoms: Int
    let numBlocks: Int
    let maxTiles: UInt32
    let maxForceMagnitude: Double
    let referenceOpenCLAgreement: AgreementStats
    let metalTranslationAgreement: AgreementStats
    let metalNativeVariantAAgreement: AgreementStats
    let metalNativeVariantBAgreement: AgreementStats
    let metalNativeVariantCAgreement: AgreementStats
    let mutationGateResults: [MutationGateResult]
    let agreementVerified: Bool
    let standaloneComputeNonbonded: [String: TimingStats]
    let ablationMatrix: [AblationRow]
    let threadgroupSweepNative: [String: TimingStats]
    let threadgroupSweepTranslation: [String: TimingStats]
}

struct BenchmarkOutput: Codable {
    let chip: String
    let osVersion: String
    let osBuild: String
    let gpuCores: Int
    let reportedSimdWidth: Int
    let kernelSimdWidth: Int
    let statedTolerancePpm: Double
    let benchmarks: [String: BenchmarkCaseResult]
}

// MARK: - Utility Functions

func getSysctlString(_ name: String) -> String {
    var size = 0
    sysctlbyname(name, nil, &size, nil, 0)
    var buffer = [CChar](repeating: 0, count: size)
    sysctlbyname(name, &buffer, &size, nil, 0)
    return String(cString: buffer)
}

func getOsBuild() -> String {
    return getSysctlString("kern.osversion")
}

func getOsProductVersion() -> String {
    let url = URL(fileURLWithPath: "/System/Library/CoreServices/SystemVersion.plist")
    guard let data = try? Data(contentsOf: url),
          let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
          let version = plist["ProductVersion"] as? String else {
        return "macOS"
    }
    return version
}

func pad(_ s: String, _ w: Int) -> String {
    if s.count >= w { return s }
    return s + String(repeating: " ", count: w - s.count)
}

func padLeft(_ s: String, _ w: Int) -> String {
    if s.count >= w { return s }
    return String(repeating: " ", count: w - s.count) + s
}

func executeMetalCommandBuffer(_ cmd: MTLCommandBuffer, name: String, timeoutSeconds: Double = 15.0) {
    let sema = DispatchSemaphore(value: 0)
    cmd.addCompletedHandler { _ in sema.signal() }
    cmd.commit()
    let timeoutResult = sema.wait(timeout: .now() + timeoutSeconds)
    if timeoutResult == .timedOut {
        fputs("ERROR: Metal command buffer timed out after \(timeoutSeconds)s on \(name). Status: \(cmd.status.rawValue)\n", stderr)
        exit(1)
    }
    if cmd.status == .error {
        fputs("ERROR: Metal command buffer failed on \(name): \(String(describing: cmd.error))\n", stderr)
        exit(1)
    }
}

func executeOpenCLWithTimeout(_ queue: cl_command_queue, name: String, timeoutSeconds: Double = 15.0) {
    let sema = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        clFinish(queue)
        sema.signal()
    }
    let timeoutResult = sema.wait(timeout: .now() + timeoutSeconds)
    if timeoutResult == .timedOut {
        fputs("ERROR: OpenCL clFinish timed out after \(timeoutSeconds)s on \(name)\n", stderr)
        exit(1)
    }
}

func extractCapturesIfNeeded(capturesDir: String, targetDir: String) {
    let fm = FileManager.default
    for name in ["apoa1rf", "apoa1pme"] {
        let metaPath = "\(targetDir)/\(name)/metadata.json"
        if !fm.fileExists(atPath: metaPath) {
            var tarPath = "\(capturesDir)/\(name).tar.gz"
            if !fm.fileExists(atPath: tarPath) {
                tarPath = "\(capturesDir)/../010-compute-nonbonded/captures/\(name).tar.gz"
            }
            guard fm.fileExists(atPath: tarPath) else {
                fputs("ERROR: Missing capture archive for \(name): \(tarPath)\n", stderr)
                exit(1)
            }
            try? fm.createDirectory(atPath: "\(targetDir)/\(name)", withIntermediateDirectories: true)
            print("Extracting \(tarPath) -> \(targetDir)/\(name)...")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            p.arguments = ["-xzf", tarPath, "-C", "\(targetDir)/\(name)"]
            try! p.run()
            p.waitUntilExit()
            if p.terminationStatus != 0 {
                fputs("ERROR: Failed to extract capture: \(tarPath)\n", stderr)
                exit(1)
            }
        }
    }
}

// MARK: - Benchmark Runner

class BenchmarkRunner {
    let name: String
    let capDir: String
    let kernelsDir: String
    let numRepeats: Int
    let isPME: Bool
    let tolerancePpm: Double = 10.0

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
    let refFBData: Data
    let posqData: Data
    let exclData: Data
    let exclTilesData: Data
    let tilesData: Data
    let countData: Data
    let centerData: Data
    let sizeData: Data
    let atomsData: Data
    let paramsData: Data

    let refFB: [Int64]
    let maxForceMag: Double

    let metalDevice: MTLDevice
    let metalQueue: MTLCommandQueue

    var clPlatform: cl_platform_id?
    var clDevice: cl_device_id?
    var clContext: cl_context?
    var clQueue: cl_command_queue?

    init(name: String, capDir: String, kernelsDir: String, numRepeats: Int = 20) {
        self.name = name
        self.capDir = capDir
        self.kernelsDir = kernelsDir
        self.numRepeats = numRepeats
        self.isPME = (name == "apoa1pme")

        let metaUrl = URL(fileURLWithPath: "\(capDir)/metadata.json")
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

        func loadData(_ fn: String) -> Data {
            let url = URL(fileURLWithPath: "\(capDir)/\(fn)")
            return try! Data(contentsOf: url)
        }

        self.fbBeforeData = loadData("forceBuffers_before.bin")
        let refData = loadData("forceBuffers_after.bin")
        self.refFBData = refData
        self.posqData = loadData("posq.bin")
        self.exclData = loadData("exclusions.bin")
        self.exclTilesData = loadData("exclusionTiles.bin")
        self.tilesData = loadData("interactingTiles_after_findBlocksWithInteractions.bin")
        self.countData = loadData("interactionCount_after_findBlocksWithInteractions.bin")
        self.centerData = loadData("blockCenter_after_findBlockBounds.bin")
        self.sizeData = loadData("blockBoundingBox_after_findBlockBounds.bin")
        self.atomsData = loadData("interactingAtoms_after_findBlocksWithInteractions.bin")
        self.paramsData = loadData("param_0_nonbonded2_sigmaEpsilon.bin")

        let wordCount = refData.count / MemoryLayout<Int64>.stride
        var fbArray = [Int64](repeating: 0, count: wordCount)
        _ = fbArray.withUnsafeMutableBytes { ptr in
            refData.copyBytes(to: ptr)
        }
        self.refFB = fbArray

        var maxRef: Int64 = 0
        for val in self.refFB {
            let a = abs(val)
            if a > maxRef { maxRef = a }
        }
        self.maxForceMag = Double(maxRef) / 4294967296.0

        self.metalDevice = MTLCreateSystemDefaultDevice()!
        self.metalQueue = self.metalDevice.makeCommandQueue()!

        var err: cl_int = 0
        clGetPlatformIDs(1, &self.clPlatform, nil)
        clGetDeviceIDs(self.clPlatform, cl_device_type(CL_DEVICE_TYPE_GPU), 1, &self.clDevice, nil)
        self.clContext = clCreateContext(nil, 1, &self.clDevice, nil, nil, &err)
        self.clQueue = clCreateCommandQueue(self.clContext, self.clDevice, cl_command_queue_properties(CL_QUEUE_PROFILING_ENABLE), &err)
    }

    func makeMtlBuf(_ data: Data) -> MTLBuffer {
        return data.withUnsafeBytes { ptr in
            self.metalDevice.makeBuffer(bytes: ptr.baseAddress!, length: data.count, options: .storageModeShared)!
        }
    }

    func compileOpenCLKernel(extraDefs: [String] = []) -> cl_kernel {
        let prefix = self.isPME ? "computeNonbonded_pme" : "computeNonbonded_rf"
        let clSrcPath = "\(self.kernelsDir)/\(prefix).full.cl"
        let clSrc = try! String(contentsOfFile: clSrcPath, encoding: .utf8)
        var cStr: UnsafePointer<CChar>? = (clSrc as NSString).utf8String
        var err: cl_int = 0
        let prog = clCreateProgramWithSource(self.clContext, 1, &cStr, nil, &err)
        let defsStr = extraDefs.map { "-D\($0)=1" }.joined(separator: " ")
        clBuildProgram(prog, 1, &self.clDevice, "-cl-mad-enable -cl-no-signed-zeros \(defsStr)", nil, nil)
        let k = clCreateKernel(prog, "computeNonbonded", &err)
        if k == nil {
            fputs("ERROR: Failed to create OpenCL kernel\n", stderr)
            exit(1)
        }
        return k!
    }

    func compileMetalTranslation(extraDefs: [String] = []) -> MTLComputePipelineState {
        let prelude = try! String(contentsOfFile: "\(self.kernelsDir)/prelude.metal", encoding: .utf8)
        let prefix = self.isPME ? "computeNonbonded_pme" : "computeNonbonded_rf"
        let body = try! String(contentsOfFile: "\(self.kernelsDir)/\(prefix).body.cl", encoding: .utf8)
        let defs = try! String(contentsOfFile: "\(self.kernelsDir)/\(prefix).defines", encoding: .utf8)

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
        let lib = try! self.metalDevice.makeLibrary(source: fullTrans, options: opt)
        let fn = lib.makeFunction(name: "computeNonbonded")!
        return try! self.metalDevice.makeComputePipelineState(function: fn)
    }

    func compileMetalNative(macros: [String: NSObject]) -> MTLComputePipelineState {
        let nativeSrc = try! String(contentsOfFile: "\(self.kernelsDir)/computeNonbonded_native.metal", encoding: .utf8)
        let opt = MTLCompileOptions()
        opt.languageVersion = .version3_1
        var allMacros = macros
        if self.isPME {
            allMacros["USE_PME"] = NSNumber(value: 1)
        }
        opt.preprocessorMacros = allMacros
        let lib = try! self.metalDevice.makeLibrary(source: nativeSrc, options: opt)
        let fn = lib.makeFunction(name: "computeNonbonded")!
        return try! self.metalDevice.makeComputePipelineState(function: fn)
    }

    func evaluateAgreement(bufFB: MTLBuffer, bufEB: MTLBuffer, refEnergy: Double? = nil) -> AgreementStats {
        let outPtr = bufFB.contents().bindMemory(to: Int64.self, capacity: self.refFB.count)
        var maxDiff: Int64 = 0
        var exact = 0

        for i in 0..<self.refFB.count {
            let diff = abs(outPtr[i] - self.refFB[i])
            if diff == 0 {
                exact += 1
            } else if diff > maxDiff {
                maxDiff = diff
            }
        }

        let maxAbs = Double(maxDiff) / 4294967296.0
        let ppm = (maxAbs / self.maxForceMag) * 1e6

        var energyDiff: Double = 0.0
        var energyPpm: Double = 0.0
        if let refE = refEnergy {
            let ebPtr = bufEB.contents().bindMemory(to: Float.self, capacity: 15360)
            var totalE: Double = 0.0
            for i in 0..<15360 { totalE += Double(ebPtr[i]) }
            energyDiff = abs(totalE - refE)
            energyPpm = (energyDiff / abs(refE)) * 1e6
        }

        let passed = (ppm < self.tolerancePpm) && (energyPpm < self.tolerancePpm)
        return AgreementStats(
            maxDiffFixedPoint: maxDiff,
            maxAbsForceDiff: maxAbs,
            forcePpm: ppm,
            exactMatches: exact,
            totalWords: self.refFB.count,
            energyDiff: energyDiff,
            energyPpm: energyPpm,
            passed: passed
        )
    }

    func runMetalPipelineAgreement(pso: MTLComputePipelineState, refEnergy: Double? = nil) -> (AgreementStats, Double) {
        let bufFB = self.makeMtlBuf(self.fbBeforeData)
        var zeroEnergy = [Float](repeating: 0.0, count: 15360)
        let bufEB = self.metalDevice.makeBuffer(bytes: &zeroEnergy, length: 15360 * 4, options: .storageModeShared)!
        let bufPosq = self.makeMtlBuf(self.posqData)
        let bufExcl = self.makeMtlBuf(self.exclData)
        let bufExclTiles = self.makeMtlBuf(self.exclTilesData)
        let bufTiles = self.makeMtlBuf(self.tilesData)
        let bufCount = self.makeMtlBuf(self.countData)
        let bufCenter = self.makeMtlBuf(self.centerData)
        let bufSize = self.makeMtlBuf(self.sizeData)
        let bufAtoms = self.makeMtlBuf(self.atomsData)
        let bufParams = self.makeMtlBuf(self.paramsData)

        let cmd = self.metalQueue.makeCommandBuffer()!
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

        let numGroups = (60 * 256) / 32
        enc.dispatchThreadgroups(MTLSize(width: numGroups, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 32, height: 1, depth: 1))
        enc.endEncoding()

        executeMetalCommandBuffer(cmd, name: "Metal agreement run")

        let ebPtr = bufEB.contents().bindMemory(to: Float.self, capacity: 15360)
        var totalE: Double = 0.0
        for i in 0..<15360 { totalE += Double(ebPtr[i]) }

        let stats = self.evaluateAgreement(bufFB: bufFB, bufEB: bufEB, refEnergy: refEnergy)
        return (stats, totalE)
    }

    func runOpenCLAgreement() -> (AgreementStats, Double) {
        let clKernel = self.compileOpenCLKernel(extraDefs: ["INCLUDE_ENERGY"])
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

        clSetKernelArg(clKernel, 0, MemoryLayout<cl_mem>.size, &bufClFB)
        clSetKernelArg(clKernel, 1, MemoryLayout<cl_mem>.size, &bufClEB)
        clSetKernelArg(clKernel, 2, MemoryLayout<cl_mem>.size, &bufClPosq)
        clSetKernelArg(clKernel, 3, MemoryLayout<cl_mem>.size, &bufClExcl)
        clSetKernelArg(clKernel, 4, MemoryLayout<cl_mem>.size, &bufClExclTiles)
        clSetKernelArg(clKernel, 5, MemoryLayout<cl_uint>.size, &self.startTileIndex)
        clSetKernelArg(clKernel, 6, MemoryLayout<cl_ulong>.size, &self.numTileIndices)
        clSetKernelArg(clKernel, 7, MemoryLayout<cl_mem>.size, &bufClTiles)
        clSetKernelArg(clKernel, 8, MemoryLayout<cl_mem>.size, &bufClCount)
        clSetKernelArg(clKernel, 9, MemoryLayout<Float4Param>.size, &self.pBox)
        clSetKernelArg(clKernel, 10, MemoryLayout<Float4Param>.size, &self.invBox)
        clSetKernelArg(clKernel, 11, MemoryLayout<Float4Param>.size, &self.pVecX)
        clSetKernelArg(clKernel, 12, MemoryLayout<Float4Param>.size, &self.pVecY)
        clSetKernelArg(clKernel, 13, MemoryLayout<Float4Param>.size, &self.pVecZ)
        clSetKernelArg(clKernel, 14, MemoryLayout<cl_uint>.size, &self.maxTiles)
        clSetKernelArg(clKernel, 15, MemoryLayout<cl_mem>.size, &bufClCenter)
        clSetKernelArg(clKernel, 16, MemoryLayout<cl_mem>.size, &bufClSize)
        clSetKernelArg(clKernel, 17, MemoryLayout<cl_mem>.size, &bufClAtoms)
        clSetKernelArg(clKernel, 18, MemoryLayout<cl_mem>.size, &bufClParams)

        var gWork: size_t = 60 * 256
        var lWork: size_t = 256

        var ev: cl_event?
        clEnqueueNDRangeKernel(self.clQueue, clKernel, 1, nil, &gWork, &lWork, 0, nil, &ev)
        executeOpenCLWithTimeout(self.clQueue!, name: "OpenCL agreement run")
        clReleaseEvent(ev)

        var clOut = [Int64](repeating: 0, count: self.refFB.count)
        clEnqueueReadBuffer(self.clQueue, bufClFB, cl_bool(CL_TRUE), 0, self.refFB.count * 8, &clOut, 0, nil, nil)

        var exact = 0
        var maxDiff: Int64 = 0
        for i in 0..<self.refFB.count {
            let diff = abs(clOut[i] - self.refFB[i])
            if diff == 0 {
                exact += 1
            } else if diff > maxDiff {
                maxDiff = diff
            }
        }

        var clEBOut = [Float](repeating: 0.0, count: 15360)
        clEnqueueReadBuffer(self.clQueue, bufClEB, cl_bool(CL_TRUE), 0, 15360 * 4, &clEBOut, 0, nil, nil)
        var totalE: Double = 0.0
        for i in 0..<15360 { totalE += Double(clEBOut[i]) }

        let maxAbs = Double(maxDiff) / 4294967296.0
        let ppm = (maxAbs / self.maxForceMag) * 1e6

        return (
            AgreementStats(
                maxDiffFixedPoint: maxDiff,
                maxAbsForceDiff: maxAbs,
                forcePpm: ppm,
                exactMatches: exact,
                totalWords: self.refFB.count,
                energyDiff: 0.0,
                energyPpm: 0.0,
                passed: (ppm < self.tolerancePpm)
            ),
            totalE
        )
    }

    func timeOpenCL(kernel: cl_kernel) -> TimingStats {
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

        // Warmup: 5 iterations
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
        for _ in 0..<self.numRepeats {
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

    func timeMetal(pso: MTLComputePipelineState, groupSize: Int, useTG: Bool = true) -> TimingStats {
        let bufFB = self.makeMtlBuf(self.fbBeforeData)
        var zeroEnergy = [Float](repeating: 0.0, count: 15360)
        let bufEB = self.metalDevice.makeBuffer(bytes: &zeroEnergy, length: 15360 * 4, options: .storageModeShared)!
        let bufPosq = self.makeMtlBuf(self.posqData)
        let bufExcl = self.makeMtlBuf(self.exclData)
        let bufExclTiles = self.makeMtlBuf(self.exclTilesData)
        let bufTiles = self.makeMtlBuf(self.tilesData)
        let bufCount = self.makeMtlBuf(self.countData)
        let bufCenter = self.makeMtlBuf(self.centerData)
        let bufSize = self.makeMtlBuf(self.sizeData)
        let bufAtoms = self.makeMtlBuf(self.atomsData)
        let bufParams = self.makeMtlBuf(self.paramsData)

        // Warmup: 5 iterations
        for _ in 0..<5 {
            _ = self.fbBeforeData.withUnsafeBytes { ptr in
                memcpy(bufFB.contents(), ptr.baseAddress!, self.fbBeforeData.count)
            }
            let cmd = self.metalQueue.makeCommandBuffer()!
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
        for _ in 0..<self.numRepeats {
            _ = self.fbBeforeData.withUnsafeBytes { ptr in
                memcpy(bufFB.contents(), ptr.baseAddress!, self.fbBeforeData.count)
            }
            let cmd = self.metalQueue.makeCommandBuffer()!
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

    func run() -> BenchmarkCaseResult {
        print("\n========================================================")
        print("Running benchmark case: \(self.name)")
        print("Atoms: \(self.numAtoms), Blocks: \(self.numBlocks), MaxTiles: \(self.maxTiles)")
        print("Max Force Magnitude: \(String(format: "%.2f", self.maxForceMag)) kJ/(mol*nm)")
        print("Tolerance: < \(self.tolerancePpm) ppm")
        print("========================================================")

        // Step 1: Agreement Verification
        print("\n[Step 1: Agreement Verification]")
        let (clStats, clEnergy) = self.runOpenCLAgreement()
        print("  Apple OpenCL vs Reference: max diff \(clStats.maxDiffFixedPoint) fp, \(String(format: "%.6f", clStats.maxAbsForceDiff)) kJ/(mol*nm), \(String(format: "%.4f", clStats.forcePpm)) ppm [\(clStats.passed ? "PASS" : "FAIL")]")

        let psoTrans = self.compileMetalTranslation(extraDefs: ["INCLUDE_ENERGY"])
        let (transStats, computedEnergyTrans) = self.runMetalPipelineAgreement(pso: psoTrans, refEnergy: clEnergy)
        print("  Metal Straight Translation: max diff \(transStats.maxDiffFixedPoint) fp, \(String(format: "%.6f", transStats.maxAbsForceDiff)) kJ/(mol*nm), \(String(format: "%.4f", transStats.forcePpm)) ppm, Energy: \(String(format: "%.2f", computedEnergyTrans)) kJ/mol [\(transStats.passed ? "PASS" : "FAIL")]")

        let psoNativeA = self.compileMetalNative(macros: ["INCLUDE_ENERGY": NSNumber(value: 1)])
        let (nativeAStats, computedEnergyNativeA) = self.runMetalPipelineAgreement(pso: psoNativeA, refEnergy: computedEnergyTrans)
        print("  Metal Native Variant A (SIMD Shuffle): max diff \(nativeAStats.maxDiffFixedPoint) fp, \(String(format: "%.6f", nativeAStats.maxAbsForceDiff)) kJ/(mol*nm), \(String(format: "%.4f", nativeAStats.forcePpm)) ppm, Energy: \(String(format: "%.2f", computedEnergyNativeA)) kJ/mol [\(nativeAStats.passed ? "PASS" : "FAIL")]")

        let psoNativeB = self.compileMetalNative(macros: ["INCLUDE_ENERGY": NSNumber(value: 1), "ENABLE_FORCE_ACCUMULATION": NSNumber(value: 1)])
        let (nativeBStats, _) = self.runMetalPipelineAgreement(pso: psoNativeB, refEnergy: computedEnergyTrans)
        print("  Metal Native Variant B (SIMD Shuffle + Acc): max diff \(nativeBStats.maxDiffFixedPoint) fp, \(String(format: "%.6f", nativeBStats.maxAbsForceDiff)) kJ/(mol*nm), \(String(format: "%.4f", nativeBStats.forcePpm)) ppm [\(nativeBStats.passed ? "PASS" : "FAIL")]")

        let psoNativeC = self.compileMetalNative(macros: ["INCLUDE_ENERGY": NSNumber(value: 1), "ENABLE_FORCE_ACCUMULATION": NSNumber(value: 1), "ENABLE_OPTIMIZED": NSNumber(value: 1)])
        let (nativeCStats, _) = self.runMetalPipelineAgreement(pso: psoNativeC, refEnergy: computedEnergyTrans)
        print("  Metal Native Variant C (Optimized unroll): max diff \(nativeCStats.maxDiffFixedPoint) fp, \(String(format: "%.6f", nativeCStats.maxAbsForceDiff)) kJ/(mol*nm), \(String(format: "%.4f", nativeCStats.forcePpm)) ppm [\(nativeCStats.passed ? "PASS" : "FAIL")]")

        let agreementPassed = clStats.passed && transStats.passed && nativeAStats.passed && nativeBStats.passed && nativeCStats.passed
        if !agreementPassed {
            fputs("FATAL: Numerical agreement check failed stated tolerance of \(self.tolerancePpm) ppm\n", stderr)
            exit(1)
        }

        // Step 2: Mutation Tests
        print("\n[Step 2: Gate Sensitivity Tests]")
        var mutationResults: [MutationGateResult] = []

        let psoMutA = self.compileMetalNative(macros: ["INCLUDE_ENERGY": NSNumber(value: 1), "MUTATE_VARIANT_A": NSNumber(value: 1)])
        let (mutAStats, _) = self.runMetalPipelineAgreement(pso: psoMutA)
        let gateA = !mutAStats.passed
        print("  Mutation A (+5% force magnitude): \(String(format: "%.1f", mutAStats.forcePpm)) ppm -> Gate \(gateA ? "CAUGHT (PASS)" : "MISSED (FAIL)")")
        mutationResults.append(MutationGateResult(mutation: "Variant A force magnitude (+5%)", targetPpm: mutAStats.forcePpm, gateDetected: gateA))

        let psoMutB = self.compileMetalNative(macros: ["INCLUDE_ENERGY": NSNumber(value: 1), "ENABLE_FORCE_ACCUMULATION": NSNumber(value: 1), "MUTATE_VARIANT_B": NSNumber(value: 1)])
        let (mutBStats, _) = self.runMetalPipelineAgreement(pso: psoMutB)
        let gateB = !mutBStats.passed
        print("  Mutation B (force accumulation offset): \(String(format: "%.1f", mutBStats.forcePpm)) ppm -> Gate \(gateB ? "CAUGHT (PASS)" : "MISSED (FAIL)")")
        mutationResults.append(MutationGateResult(mutation: "Variant B force accumulation offset", targetPpm: mutBStats.forcePpm, gateDetected: gateB))

        let psoMutE = self.compileMetalNative(macros: ["INCLUDE_ENERGY": NSNumber(value: 1), "MUTATE_ENERGY": NSNumber(value: 1)])
        let (mutEStats, _) = self.runMetalPipelineAgreement(pso: psoMutE, refEnergy: computedEnergyTrans)
        let gateE = (mutEStats.energyPpm > self.tolerancePpm)
        print("  Mutation Energy (scaled +10%): \(String(format: "%.1f", mutEStats.energyPpm)) ppm -> Gate \(gateE ? "CAUGHT (PASS)" : "MISSED (FAIL)")")
        mutationResults.append(MutationGateResult(mutation: "Energy scaled +10%", targetPpm: mutEStats.energyPpm, gateDetected: gateE))

        let allMutationsCaught = gateA && gateB && gateE
        if !allMutationsCaught {
            fputs("FATAL: Mutation test failed - verification gate did not catch artificial bug\n", stderr)
            exit(1)
        }

        // Step 3: Standalone Parity Benchmarks
        print("\n[Step 3: Standalone Parity Benchmarks (\(self.numRepeats) runs)]")
        var standalone: [String: TimingStats] = [:]

        print("  Benchmarking OpenCL (forces only, no energy)...")
        let clKernelNoEnergy = self.compileOpenCLKernel(extraDefs: [])
        standalone["opencl_no_energy"] = self.timeOpenCL(kernel: clKernelNoEnergy)

        print("  Benchmarking OpenCL (with energy)...")
        let clKernelWithEnergy = self.compileOpenCLKernel(extraDefs: ["INCLUDE_ENERGY"])
        standalone["opencl_with_energy"] = self.timeOpenCL(kernel: clKernelWithEnergy)

        print("  Benchmarking Metal Translation (forces only, no energy)...")
        let psoTransNoEnergy = self.compileMetalTranslation(extraDefs: [])
        standalone["metal_translation_no_energy"] = self.timeMetal(pso: psoTransNoEnergy, groupSize: 256, useTG: true)

        print("  Benchmarking Metal Translation (with energy)...")
        standalone["metal_translation_with_energy"] = self.timeMetal(pso: psoTrans, groupSize: 256, useTG: true)

        print("  Benchmarking Metal Native C (forces only, tg=32, dispatchThreadgroups)...")
        let psoNativeCNoEnergy = self.compileMetalNative(macros: ["ENABLE_FORCE_ACCUMULATION": NSNumber(value: 1), "ENABLE_OPTIMIZED": NSNumber(value: 1)])
        standalone["metal_native_c_no_energy_tg_32"] = self.timeMetal(pso: psoNativeCNoEnergy, groupSize: 32, useTG: true)

        print("  Benchmarking Metal Native C (forces only, tg=256, dispatchThreadgroups)...")
        standalone["metal_native_c_no_energy_tg_256"] = self.timeMetal(pso: psoNativeCNoEnergy, groupSize: 256, useTG: true)

        print("  Benchmarking Metal Native C (forces only, tg=256, dispatchThreads)...")
        standalone["metal_native_c_no_energy_threads_256"] = self.timeMetal(pso: psoNativeCNoEnergy, groupSize: 256, useTG: false)

        print("  Benchmarking Metal Native C (with energy, tg=32, dispatchThreadgroups)...")
        standalone["metal_native_c_with_energy_tg_32"] = self.timeMetal(pso: psoNativeC, groupSize: 32, useTG: true)

        print("  Benchmarking Metal Native C (with energy, tg=256, dispatchThreadgroups)...")
        standalone["metal_native_c_with_energy_tg_256"] = self.timeMetal(pso: psoNativeC, groupSize: 256, useTG: true)

        // Step 4: Ablation Matrix
        print("\n[Step 4: Ablation Matrix (\(self.numRepeats) runs)]")
        var ablationRows: [AblationRow] = []
        let ablationDefs: [(id: String, desc: String, defs: [String])] = [
            ("baseline_no_energy", "Baseline (forces only, no energy)", []),
            ("baseline_with_energy", "Baseline (with energy)", ["INCLUDE_ENERGY"]),
            ("ablation_a_no_atomic", "(a) Force writeback: non-atomic store into private slot", ["ABLATION_A_NO_ATOMIC"]),
            ("ablation_b_no_fixed_point", "(b) Fixed-point removed: direct float cast", ["ABLATION_B_NO_FIXED_POINT"]),
            ("ablation_c_no_exclusions", "(c) Exclusions removed: skip loop 1", ["ABLATION_C_NO_EXCLUSIONS"]),
            ("ablation_e_memory_only", "(e) Arithmetic stubbed: memory pattern preserved", ["ABLATION_E_MEMORY_ONLY"]),
            ("ablation_f_arithmetic_only", "(f) Memory stubbed: arithmetic executed", ["ABLATION_F_ARITHMETIC_ONLY"])
        ]

        for ab in ablationDefs {
            let clK = self.compileOpenCLKernel(extraDefs: ab.defs)
            let clStats = self.timeOpenCL(kernel: clK)

            var transTiming: TimingStats? = nil
            if ab.id != "ablation_e_memory_only" && ab.id != "ablation_f_arithmetic_only" {
                let transP = self.compileMetalTranslation(extraDefs: ab.defs)
                transTiming = self.timeMetal(pso: transP, groupSize: 256, useTG: true)
            }

            var mtlMacros: [String: NSObject] = [
                "ENABLE_FORCE_ACCUMULATION": NSNumber(value: 1),
                "ENABLE_OPTIMIZED": NSNumber(value: 1)
            ]
            for d in ab.defs {
                mtlMacros[d] = NSNumber(value: 1)
            }
            let mtlP = self.compileMetalNative(macros: mtlMacros)
            let nat256Stats = self.timeMetal(pso: mtlP, groupSize: 256, useTG: true)
            let nat32Stats = self.timeMetal(pso: mtlP, groupSize: 32, useTG: true)

            let gap = nat32Stats.median - clStats.median
            let row = AblationRow(
                id: ab.id,
                description: ab.desc,
                opencl: clStats,
                metalTranslation: transTiming,
                metalNative256: nat256Stats,
                metalNative32: nat32Stats,
                gapNat32VsCl: gap
            )
            ablationRows.append(row)
        }

        // Step 5: Threadgroup Sweep
        print("\n[Step 5: Threadgroup Sweep]")
        var sweepNative: [String: TimingStats] = [:]
        var sweepTrans: [String: TimingStats] = [:]

        for tg in [32, 64, 128, 256, 512] {
            print("  Sweeping Native Variant C tg=\(tg)...")
            sweepNative["\(tg)"] = self.timeMetal(pso: psoNativeCNoEnergy, groupSize: tg, useTG: true)
        }
        for tg in [64, 128, 256] {
            print("  Sweeping Translation tg=\(tg)...")
            sweepTrans["\(tg)"] = self.timeMetal(pso: psoTransNoEnergy, groupSize: tg, useTG: true)
        }

        return BenchmarkCaseResult(
            numAtoms: self.numAtoms,
            numBlocks: self.numBlocks,
            maxTiles: self.maxTiles,
            maxForceMagnitude: self.maxForceMag,
            referenceOpenCLAgreement: clStats,
            metalTranslationAgreement: transStats,
            metalNativeVariantAAgreement: nativeAStats,
            metalNativeVariantBAgreement: nativeBStats,
            metalNativeVariantCAgreement: nativeCStats,
            mutationGateResults: mutationResults,
            agreementVerified: agreementPassed && allMutationsCaught,
            standaloneComputeNonbonded: standalone,
            ablationMatrix: ablationRows,
            threadgroupSweepNative: sweepNative,
            threadgroupSweepTranslation: sweepTrans
        )
    }
}

// MARK: - Main CLI Entrypoint

var outPath: String? = nil
var capturesDir = "captures"
var kernelsDir = "kernels"
var numRepeats = 20
var benchmarkTarget = "all"

var args = CommandLine.arguments
var i = 1
while i < args.count {
    let arg = args[i]
    if arg == "--out" && i + 1 < args.count {
        outPath = args[i + 1]
        i += 2
    } else if arg == "--captures-dir" && i + 1 < args.count {
        capturesDir = args[i + 1]
        i += 2
    } else if arg == "--kernels-dir" && i + 1 < args.count {
        kernelsDir = args[i + 1]
        i += 2
    } else if arg == "--repeats" && i + 1 < args.count {
        numRepeats = Int(args[i + 1]) ?? 20
        i += 2
    } else if arg == "--benchmark" && i + 1 < args.count {
        benchmarkTarget = args[i + 1]
        i += 2
    } else {
        i += 1
    }
}

let tempDir = "/tmp/openmm_010_captures"
extractCapturesIfNeeded(capturesDir: capturesDir, targetDir: tempDir)

let dev = MTLCreateSystemDefaultDevice()!
let chipName = dev.name
let osVersion = getOsProductVersion()
let osBuild = getOsBuild()
let reportedSimdWidth = dev.maxThreadsPerThreadgroup.width >= 32 ? 32 : dev.maxThreadsPerThreadgroup.width

// Get GPU core count
var gpuCores = 10
if chipName.contains("Ultra") {
    gpuCores = 60
} else if chipName.contains("Max") {
    gpuCores = 30
} else if chipName.contains("Pro") {
    gpuCores = 16
}

print("========================================================")
print("Experiment 010b: computeNonbonded M2 Gap Investigation")
print("Chip: \(chipName) (\(gpuCores) GPU cores)")
print("OS: \(osVersion) (Build \(osBuild))")
print("Stated Tolerance: < 10.0 ppm")
print("========================================================")

var benchmarkResults: [String: BenchmarkCaseResult] = [:]
let casesToRun = (benchmarkTarget == "all" ? ["apoa1rf", "apoa1pme"] : [benchmarkTarget])

for c in casesToRun {
    let runner = BenchmarkRunner(name: c, capDir: "\(tempDir)/\(c)", kernelsDir: kernelsDir, numRepeats: numRepeats)
    let res = runner.run()
    benchmarkResults[c] = res
}

let finalOutput = BenchmarkOutput(
    chip: chipName,
    osVersion: osVersion,
    osBuild: osBuild,
    gpuCores: gpuCores,
    reportedSimdWidth: reportedSimdWidth,
    kernelSimdWidth: 32,
    statedTolerancePpm: 10.0,
    benchmarks: benchmarkResults
)

if let outPath = outPath {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let jsonData = try! encoder.encode(finalOutput)
    try! jsonData.write(to: URL(fileURLWithPath: outPath))
    print("\nSaved benchmark results to \(outPath)")
}

// Print Parity Summary Table
print("\n==========================================================================================================")
print("Energy Parity Summary: computeNonbonded on \(chipName) (Median of \(numRepeats) runs)")
print("==========================================================================================================")
print("\(pad("Benchmark", 10)) | \(pad("Mode", 12)) | \(pad("OpenCL", 12)) | \(pad("Mtl Trans", 12)) | \(pad("Mtl Nat(256)", 13)) | \(pad("Mtl Nat(32)", 13)) | \(pad("Gap (Nat-CL)", 13))")
print(String(repeating: "-", count: 96))

for c in casesToRun {
    if let res = benchmarkResults[c] {
        let clNoE = res.standaloneComputeNonbonded["opencl_no_energy"]?.median ?? 0
        let transNoE = res.standaloneComputeNonbonded["metal_translation_no_energy"]?.median ?? 0
        let nat256NoE = res.standaloneComputeNonbonded["metal_native_c_no_energy_tg_256"]?.median ?? 0
        let nat32NoE = res.standaloneComputeNonbonded["metal_native_c_no_energy_tg_32"]?.median ?? 0
        let gapNoE = nat32NoE - clNoE

        let clWithE = res.standaloneComputeNonbonded["opencl_with_energy"]?.median ?? 0
        let transWithE = res.standaloneComputeNonbonded["metal_translation_with_energy"]?.median ?? 0
        let nat256WithE = res.standaloneComputeNonbonded["metal_native_c_with_energy_tg_256"]?.median ?? 0
        let nat32WithE = res.standaloneComputeNonbonded["metal_native_c_with_energy_tg_32"]?.median ?? 0
        let gapWithE = nat32WithE - clWithE

        print("\(pad(c, 10)) | \(pad("Force-Only", 12)) | \(padLeft(String(format: "%.4f ms", clNoE), 12)) | \(padLeft(String(format: "%.4f ms", transNoE), 12)) | \(padLeft(String(format: "%.4f ms", nat256NoE), 13)) | \(padLeft(String(format: "%.4f ms", nat32NoE), 13)) | \(padLeft(String(format: "%+.4f ms", gapNoE), 13))")
        print("\(pad(c, 10)) | \(pad("Force+Energy", 12)) | \(padLeft(String(format: "%.4f ms", clWithE), 12)) | \(padLeft(String(format: "%.4f ms", transWithE), 12)) | \(padLeft(String(format: "%.4f ms", nat256WithE), 13)) | \(padLeft(String(format: "%.4f ms", nat32WithE), 13)) | \(padLeft(String(format: "%+.4f ms", gapWithE), 13))")
        print(String(repeating: "-", count: 96))
    }
}

// Print Ablation Table
print("\n==========================================================================================================")
print("Ablation Matrix Summary on \(chipName)")
print("==========================================================================================================")
for c in casesToRun {
    if let res = benchmarkResults[c] {
        print("\nCase: \(c)")
        print("\(pad("Ablation Case", 28)) | \(pad("OpenCL", 12)) | \(pad("Mtl Trans", 12)) | \(pad("Mtl Nat(256)", 13)) | \(pad("Mtl Nat(32)", 13)) | \(pad("Gap (Nat32-CL)", 15))")
        print(String(repeating: "-", count: 92))
        for row in res.ablationMatrix {
            let transStr = row.metalTranslation != nil ? String(format: "%.4f ms", row.metalTranslation!.median) : "N/A"
            print("\(pad(row.id, 28)) | \(padLeft(String(format: "%.4f ms", row.opencl.median), 12)) | \(padLeft(transStr, 12)) | \(padLeft(String(format: "%.4f ms", row.metalNative256.median), 13)) | \(padLeft(String(format: "%.4f ms", row.metalNative32.median), 13)) | \(padLeft(String(format: "%+.4f ms", row.gapNat32VsCl), 15))")
        }
    }
}
print("==========================================================================================================\n")

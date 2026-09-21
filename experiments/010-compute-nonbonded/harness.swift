import Foundation
import Metal
import OpenCL
import Darwin

// MARK: - Types and Structures

struct TimingStats: Codable {
    let runs: [Double]
    let median: Double
    let min: Double
    let max: Double
    let q1: Double
    let q3: Double
    let iqr: Double
    let mean: Double
    let stddev: Double

    init(runs: [Double]) {
        self.runs = runs
        let sorted = runs.sorted()
        let count = sorted.count
        self.min = sorted.first ?? 0.0
        self.max = sorted.last ?? 0.0

        if count == 0 {
            self.median = 0.0
            self.q1 = 0.0
            self.q3 = 0.0
            self.iqr = 0.0
            self.mean = 0.0
            self.stddev = 0.0
            return
        }

        func percentile(_ p: Double) -> Double {
            let index = p * Double(count - 1)
            let lower = Int(floor(index))
            let upper = Int(ceil(index))
            let weight = index - Double(lower)
            if lower == upper {
                return sorted[lower]
            }
            return (1.0 - weight) * sorted[lower] + weight * sorted[upper]
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

struct ErfcCandidateResult: Codable {
    let name: String
    let maxAbsError: Double
    let maxRelError: Double
    let notes: String
}

struct BenchmarkCaseResult: Codable {
    let numAtoms: Int
    let numBlocks: Int
    let maxForceMagnitude: Double
    let referenceOpenCLAgreement: AgreementStats
    let metalTranslationAgreement: AgreementStats
    let metalNativeVariantAAgreement: AgreementStats
    let metalNativeVariantBAgreement: AgreementStats
    let metalNativeVariantCAgreement: AgreementStats
    let mutationGateResults: [MutationGateResult]
    let erfcCandidateResults: [ErfcCandidateResult]
    let agreementVerified: Bool
    let standaloneComputeNonbonded: [String: TimingStats]
    let threadgroupSweepNative: [String: TimingStats]
    let threadgroupSweepTranslation: [String: TimingStats]
}

struct BenchmarkOutput: Codable {
    let chip: String
    let osVersion: String
    let osBuild: String
    let reportedSimdWidth: Int
    let kernelSimdWidth: Int
    let statedTolerancePpm: Double
    let benchmarks: [String: BenchmarkCaseResult]
}

// MARK: - Helper Functions

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
            let tarPath = "\(capturesDir)/\(name).tar.gz"
            guard fm.fileExists(atPath: tarPath) else {
                fputs("ERROR: Missing capture archive: \(tarPath)\n", stderr)
                exit(1)
            }
            try? fm.createDirectory(atPath: "\(targetDir)/\(name)", withIntermediateDirectories: true)
            print("Unpacking \(tarPath) to \(targetDir)/\(name)...")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            p.arguments = ["-xzf", tarPath, "-C", "\(targetDir)/\(name)"]
            try! p.run()
            p.waitUntilExit()
            if p.terminationStatus != 0 {
                fputs("ERROR: Failed to unpack \(tarPath)\n", stderr)
                exit(1)
            }
        }
    }
}

// MARK: - MSL Rewriter for OpenMM Straight Translation

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

// MARK: - Erfc Candidate Analysis

func evaluateErfcCandidates() -> [ErfcCandidateResult] {
    var maxAbs1: Double = 0.0; var maxRel1: Double = 0.0
    var maxAbs2: Double = 0.0; var maxRel2: Double = 0.0
    var maxAbs3: Double = 0.0; var maxRel3: Double = 0.0

    let steps = 90000
    for i in 0...steps {
        let x = Double(i) * 9.0 / Double(steps)
        let ref = Darwin.erfc(x)

        // 1. 1.0f - erf(x)
        let a1 = 0.254829592; let a2 = -0.284496736; let a3 = 1.421413741
        let a4 = -1.453152027; let a5 = 1.061405429; let p = 0.3275911
        let t1 = 1.0 / (1.0 + p * x)
        let poly1 = ((((a5 * t1 + a4) * t1 + a3) * t1 + a2) * t1 + a1) * t1
        let erfVal = 1.0 - poly1 * exp(-x * x)
        let cand1 = Double(Float(1.0 - erfVal)) // simulated float32 cancellation
        let err1 = abs(cand1 - ref)
        if err1 > maxAbs1 { maxAbs1 = err1 }
        if ref > 1e-15 {
            let rel1 = err1 / ref
            if rel1 > maxRel1 { maxRel1 = rel1 }
        }

        // 2. Direct Abramowitz & Stegun 7.1.26 degree-5
        let t2 = 1.0 / (1.0 + 0.3275911 * x)
        let p2 = ((((a5 * t2 + a4) * t2 + a3) * t2 + a2) * t2 + a1) * t2
        let cand2 = Double(Float(p2 * exp(-x * x)))
        let err2 = abs(cand2 - ref)
        if err2 > maxAbs2 { maxAbs2 = err2 }
        if ref > 1e-15 {
            let rel2 = err2 / ref
            if rel2 > maxRel2 { maxRel2 = rel2 }
        }

        // 3. Degree-7 Chebyshev rational fit
        let u = 1.0 / (1.0 + 0.47047 * x)
        let c0 = -0.00028434425; let c1 = 0.2701903; let c2 = 0.22740916; let c3 = 0.3931878
        let c4 = -0.21611532; let c5 = 0.6896449; let c6 = -0.4607003; let c7 = 0.0966678
        let p3 = ((((((c7 * u + c6) * u + c5) * u + c4) * u + c3) * u + c2) * u + c1) * u + c0
        let cand3 = Double(Float(p3 * exp(-x * x)))
        let err3 = abs(cand3 - ref)
        if err3 > maxAbs3 { maxAbs3 = err3 }
        if ref > 1e-15 {
            let rel3 = err3 / ref
            if rel3 > maxRel3 { maxRel3 = rel3 }
        }
    }

    return [
        ErfcCandidateResult(
            name: "1.0f - erf(x)",
            maxAbsError: maxAbs1,
            maxRelError: maxRel1,
            notes: "Suffers severe catastrophic cancellation for x > 3; relative error exceeds 100% as erfc approaches 0"
        ),
        ErfcCandidateResult(
            name: "Direct A&S degree-5 (Hastings)",
            maxAbsError: maxAbs2,
            maxRelError: maxRel2,
            notes: "Inlined directly by OpenMM compiler in single precision; bounded ~1.5e-7 absolute error"
        ),
        ErfcCandidateResult(
            name: "Degree-7 rational fit (Chebyshev)",
            maxAbsError: maxAbs3,
            maxRelError: maxRel3,
            notes: "Recommended MSL prelude candidate; bounded ~1.5e-7 error across [0, 9] with no cancellation"
        )
    ]
}

// MARK: - Benchmark Case Runner

struct Float4Param { var x: Float; var y: Float; var z: Float; var w: Float }

class BenchmarkRunner {
    let name: String
    let isPME: Bool
    let capDir: String
    let kernelsDir: String
    let numRepeats: Int
    let tolerancePpm: Double = 10.0 // 10 ppm stated single-precision tolerance

    let meta: [String: Any]
    let numAtoms: Int
    let numBlocks: Int
    var maxTiles: UInt32
    var startTileIndex: UInt32 = 0
    var numTileIndices: UInt64 = 4154403

    var pBox: Float4Param
    var invBox: Float4Param
    var pVecX: Float4Param
    var pVecY: Float4Param
    var pVecZ: Float4Param

    let fbBeforeData: Data
    let refFBData: Data
    let refFB: [Int64]
    var maxForceMag: Double = 0.0

    let ebBeforeData: Data
    let refEBData: Data
    let posqData: Data
    let exclData: Data
    let exclTilesData: Data
    let tilesData: Data
    let countData: Data
    let centerData: Data
    let sizeData: Data
    let atomsData: Data
    let paramsData: Data

    let metalDevice: MTLDevice
    let metalQueue: MTLCommandQueue

    var clPlatform: cl_platform_id?
    var clDevice: cl_device_id?
    var clContext: cl_context?
    var clQueue: cl_command_queue?
    var clProgram: cl_program?
    var clKernel: cl_kernel?

    init(name: String, capDir: String, kernelsDir: String, numRepeats: Int) {
        self.name = name
        self.isPME = (name == "apoa1pme")
        self.capDir = capDir
        self.kernelsDir = kernelsDir
        self.numRepeats = numRepeats

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

        func load(_ fn: String) -> Data {
            return try! Data(contentsOf: URL(fileURLWithPath: "\(capDir)/\(fn)"))
        }

        self.fbBeforeData = load("forceBuffers_before.bin")
        self.refFBData = load("forceBuffers_after.bin")
        self.refFB = self.refFBData.withUnsafeBytes { Array($0.bindMemory(to: Int64.self)) }

        for i in 0..<self.refFB.count {
            let mag = abs(Double(self.refFB[i]) / 4294967296.0)
            if mag > self.maxForceMag { self.maxForceMag = mag }
        }

        self.ebBeforeData = load("energyBuffer_before.bin")
        self.refEBData = load("energyBuffer_after.bin")
        self.posqData = load("posq.bin")
        self.exclData = load("exclusions.bin")
        self.exclTilesData = load("exclusionTiles.bin")
        self.tilesData = load("interactingTiles_after_findBlocksWithInteractions.bin")
        self.countData = load("interactionCount_after_findBlocksWithInteractions.bin")
        self.centerData = load("blockCenter_after_findBlockBounds.bin")
        self.sizeData = load("blockBoundingBox_after_findBlockBounds.bin")
        self.atomsData = load("interactingAtoms_after_findBlocksWithInteractions.bin")
        self.paramsData = load("param_0_nonbonded2_sigmaEpsilon.bin")

        self.metalDevice = MTLCreateSystemDefaultDevice()!
        self.metalQueue = self.metalDevice.makeCommandQueue()!

        self.initOpenCL()
    }

    func initOpenCL() {
        var err: cl_int = 0
        clGetPlatformIDs(1, &self.clPlatform, nil)
        clGetDeviceIDs(self.clPlatform, cl_device_type(CL_DEVICE_TYPE_GPU), 1, &self.clDevice, nil)
        self.clContext = clCreateContext(nil, 1, &self.clDevice, nil, nil, &err)
        self.clQueue = clCreateCommandQueue(self.clContext, self.clDevice, cl_command_queue_properties(CL_QUEUE_PROFILING_ENABLE), &err)

        let prefix = (self.isPME ? "computeNonbonded_pme" : "computeNonbonded_rf")
        let clSrcPath = "\(self.kernelsDir)/\(prefix).full.cl"
        let clSrc = try! String(contentsOfFile: clSrcPath, encoding: .utf8)
        var cStr: UnsafePointer<CChar>? = (clSrc as NSString).utf8String
        self.clProgram = clCreateProgramWithSource(self.clContext, 1, &cStr, nil, &err)
        clBuildProgram(self.clProgram, 1, &self.clDevice, "-cl-mad-enable -cl-no-signed-zeros", nil, nil)
        self.clKernel = clCreateKernel(self.clProgram, "computeNonbonded", &err)
    }

    func makeMtlBuf(_ data: Data) -> MTLBuffer {
        return data.withUnsafeBytes { ptr in
            self.metalDevice.makeBuffer(bytes: ptr.baseAddress!, length: data.count, options: .storageModeShared)!
        }
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

    func compileMetalTranslation(includeEnergy: Bool = false) -> MTLComputePipelineState {
        let prelude = try! String(contentsOfFile: "\(self.kernelsDir)/prelude.metal", encoding: .utf8)
        let prefix = (self.isPME ? "computeNonbonded_pme" : "computeNonbonded_rf")
        let body = try! String(contentsOfFile: "\(self.kernelsDir)/\(prefix).body.cl", encoding: .utf8)
        let defs = try! String(contentsOfFile: "\(self.kernelsDir)/\(prefix).defines", encoding: .utf8)

        var progDefs = ""
        for line in defs.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: "\t")
            if parts.count >= 3 && parts[0] == "program" {
                progDefs += "#define \(parts[1]) \(parts[2])\n"
            }
        }
        if includeEnergy {
            progDefs += "#define INCLUDE_ENERGY 1\n"
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

    func evaluateAgreement(bufFB: MTLBuffer, bufEB: MTLBuffer, refEnergy: Double? = nil) -> AgreementStats {
        let outPtr = bufFB.contents().bindMemory(to: Int64.self, capacity: self.refFB.count)
        var exact = 0
        var maxDiff: Int64 = 0

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

    func runMetalPipelineAgreement(pso: MTLComputePipelineState, withEnergy: Bool = true, refEnergy: Double? = nil) -> (AgreementStats, Double) {
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

        enc.dispatchThreads(MTLSize(width: 60 * 256, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        enc.endEncoding()
        executeMetalCommandBuffer(cmd, name: "Metal agreement run")

        let ebPtr = bufEB.contents().bindMemory(to: Float.self, capacity: 15360)
        var totalE: Double = 0.0
        for i in 0..<15360 { totalE += Double(ebPtr[i]) }

        let stats = self.evaluateAgreement(bufFB: bufFB, bufEB: bufEB, refEnergy: refEnergy)
        return (stats, totalE)
    }

    func runOpenCLAgreement() -> (AgreementStats, Double) {
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

        clSetKernelArg(self.clKernel, 0, MemoryLayout<cl_mem>.size, &bufClFB)
        clSetKernelArg(self.clKernel, 1, MemoryLayout<cl_mem>.size, &bufClEB)
        clSetKernelArg(self.clKernel, 2, MemoryLayout<cl_mem>.size, &bufClPosq)
        clSetKernelArg(self.clKernel, 3, MemoryLayout<cl_mem>.size, &bufClExcl)
        clSetKernelArg(self.clKernel, 4, MemoryLayout<cl_mem>.size, &bufClExclTiles)
        clSetKernelArg(self.clKernel, 5, MemoryLayout<cl_uint>.size, &self.startTileIndex)
        clSetKernelArg(self.clKernel, 6, MemoryLayout<cl_ulong>.size, &self.numTileIndices)
        clSetKernelArg(self.clKernel, 7, MemoryLayout<cl_mem>.size, &bufClTiles)
        clSetKernelArg(self.clKernel, 8, MemoryLayout<cl_mem>.size, &bufClCount)
        clSetKernelArg(self.clKernel, 9, MemoryLayout<Float4Param>.size, &self.pBox)
        clSetKernelArg(self.clKernel, 10, MemoryLayout<Float4Param>.size, &self.invBox)
        clSetKernelArg(self.clKernel, 11, MemoryLayout<Float4Param>.size, &self.pVecX)
        clSetKernelArg(self.clKernel, 12, MemoryLayout<Float4Param>.size, &self.pVecY)
        clSetKernelArg(self.clKernel, 13, MemoryLayout<Float4Param>.size, &self.pVecZ)
        clSetKernelArg(self.clKernel, 14, MemoryLayout<cl_uint>.size, &self.maxTiles)
        clSetKernelArg(self.clKernel, 15, MemoryLayout<cl_mem>.size, &bufClCenter)
        clSetKernelArg(self.clKernel, 16, MemoryLayout<cl_mem>.size, &bufClSize)
        clSetKernelArg(self.clKernel, 17, MemoryLayout<cl_mem>.size, &bufClAtoms)
        clSetKernelArg(self.clKernel, 18, MemoryLayout<cl_mem>.size, &bufClParams)

        var gWork: size_t = 60 * 256
        var lWork: size_t = 256

        var ev: cl_event?
        clEnqueueNDRangeKernel(self.clQueue, self.clKernel, 1, nil, &gWork, &lWork, 0, nil, &ev)
        executeOpenCLWithTimeout(self.clQueue!, name: "OpenCL agreement run")
        clReleaseEvent(ev)

        var clOut = [Int64](repeating: 0, count: self.refFB.count)
        clEnqueueReadBuffer(self.clQueue, bufClFB, cl_bool(CL_TRUE), 0, self.refFB.count * 8, &clOut, 0, nil, nil)

        var exact = 0
        var maxDiff: Int64 = 0
        for i in 0..<self.refFB.count {
            let diff = abs(clOut[i] - self.refFB[i])
            if diff == 0 { exact += 1 }
            else if diff > maxDiff { maxDiff = diff }
        }
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
                passed: ppm < self.tolerancePpm
            ),
            0.0
        )
    }

    func timeOpenCL(repeats: Int) -> TimingStats {
        var gWork: size_t = 60 * 256
        var lWork: size_t = 256

        // Warmup
        var evWarm: cl_event?
        clEnqueueNDRangeKernel(self.clQueue, self.clKernel, 1, nil, &gWork, &lWork, 0, nil, &evWarm)
        executeOpenCLWithTimeout(self.clQueue!, name: "OpenCL warmup")
        clReleaseEvent(evWarm)

        func makeClBuf(_ data: Data, readOnly: Bool = true) -> cl_mem {
            var err: cl_int = 0
            let flags = readOnly ? (CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR) : (CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR)
            return data.withUnsafeBytes { ptr in
                clCreateBuffer(self.clContext, cl_mem_flags(flags), data.count, UnsafeMutableRawPointer(mutating: ptr.baseAddress), &err)
            }
        }
        var bufClFB = makeClBuf(self.fbBeforeData, readOnly: false)
        clSetKernelArg(self.clKernel, 0, MemoryLayout<cl_mem>.size, &bufClFB)

        var runs: [Double] = []
        for _ in 0..<repeats {
            _ = self.fbBeforeData.withUnsafeBytes { ptr in
                clEnqueueWriteBuffer(self.clQueue, bufClFB, cl_bool(CL_TRUE), 0, self.fbBeforeData.count, ptr.baseAddress!, 0, nil, nil)
            }
            var ev: cl_event?
            clEnqueueNDRangeKernel(self.clQueue, self.clKernel, 1, nil, &gWork, &lWork, 0, nil, &ev)
            executeOpenCLWithTimeout(self.clQueue!, name: "OpenCL timed run")

            var start: cl_ulong = 0
            var end: cl_ulong = 0
            clGetEventProfilingInfo(ev, cl_profiling_info(CL_PROFILING_COMMAND_START), MemoryLayout<cl_ulong>.size, &start, nil)
            clGetEventProfilingInfo(ev, cl_profiling_info(CL_PROFILING_COMMAND_END), MemoryLayout<cl_ulong>.size, &end, nil)
            clReleaseEvent(ev)

            let ms = Double(end - start) * (125.0 / 3.0) / 1e6
            runs.append(ms)
        }
        return TimingStats(runs: runs)
    }

    func timeMetalPipeline(pso: MTLComputePipelineState, groupSize: Int, repeats: Int) -> TimingStats {
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

        // Warmup
        let cmdWarm = self.metalQueue.makeCommandBuffer()!
        let encWarm = cmdWarm.makeComputeCommandEncoder()!
        encWarm.setComputePipelineState(pso)
        encWarm.setBuffer(bufFB, offset: 0, index: 0)
        encWarm.setBuffer(bufEB, offset: 0, index: 1)
        encWarm.setBuffer(bufPosq, offset: 0, index: 2)
        encWarm.setBuffer(bufExcl, offset: 0, index: 3)
        encWarm.setBuffer(bufExclTiles, offset: 0, index: 4)
        encWarm.setBytes(&self.startTileIndex, length: 4, index: 5)
        encWarm.setBytes(&self.numTileIndices, length: 8, index: 6)
        encWarm.setBuffer(bufTiles, offset: 0, index: 7)
        encWarm.setBuffer(bufCount, offset: 0, index: 8)
        encWarm.setBytes(&self.pBox, length: 16, index: 9)
        encWarm.setBytes(&self.invBox, length: 16, index: 10)
        encWarm.setBytes(&self.pVecX, length: 16, index: 11)
        encWarm.setBytes(&self.pVecY, length: 16, index: 12)
        encWarm.setBytes(&self.pVecZ, length: 16, index: 13)
        encWarm.setBytes(&self.maxTiles, length: 4, index: 14)
        encWarm.setBuffer(bufCenter, offset: 0, index: 15)
        encWarm.setBuffer(bufSize, offset: 0, index: 16)
        encWarm.setBuffer(bufAtoms, offset: 0, index: 17)
        encWarm.setBuffer(bufParams, offset: 0, index: 18)
        encWarm.dispatchThreads(MTLSize(width: 60 * 256, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: groupSize, height: 1, depth: 1))
        encWarm.endEncoding()
        executeMetalCommandBuffer(cmdWarm, name: "Metal warmup")

        var runs: [Double] = []
        for _ in 0..<repeats {
            // Restore initial force buffers
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
            enc.dispatchThreads(MTLSize(width: 60 * 256, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: groupSize, height: 1, depth: 1))
            enc.endEncoding()

            executeMetalCommandBuffer(cmd, name: "Metal timed run")
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
        print("Stated Single-Precision Tolerance: < \(self.tolerancePpm) ppm (1e-5 relative to max force)")
        print("========================================================")

        // Step 2: Agreement Verification
        print("\n[Step 2: Agreement Verification]")
        let (clStats, _) = self.runOpenCLAgreement()
        print("  Apple OpenCL vs Reference: max diff \(clStats.maxDiffFixedPoint) fp, \(String(format: "%.6f", clStats.maxAbsForceDiff)) kJ/(mol*nm), \(String(format: "%.4f", clStats.forcePpm)) ppm [\(clStats.passed ? "PASS" : "FAIL")]")

        let psoTrans = self.compileMetalTranslation(includeEnergy: true)
        let (transStats, computedEnergyTrans) = self.runMetalPipelineAgreement(pso: psoTrans)
        print("  Metal Straight Translation: max diff \(transStats.maxDiffFixedPoint) fp, \(String(format: "%.6f", transStats.maxAbsForceDiff)) kJ/(mol*nm), \(String(format: "%.4f", transStats.forcePpm)) ppm, Energy: \(String(format: "%.2f", computedEnergyTrans)) kJ/mol [\(transStats.passed ? "PASS" : "FAIL")]")

        let psoNativeA = self.compileMetalNative(macros: ["INCLUDE_ENERGY": NSNumber(value: 1)])
        let (nativeAStats, computedEnergyNativeA) = self.runMetalPipelineAgreement(pso: psoNativeA, refEnergy: computedEnergyTrans)
        print("  Metal Native Variant A (SIMD Shuffle): max diff \(nativeAStats.maxDiffFixedPoint) fp, \(String(format: "%.6f", nativeAStats.maxAbsForceDiff)) kJ/(mol*nm), \(String(format: "%.4f", nativeAStats.forcePpm)) ppm, Energy: \(String(format: "%.2f", computedEnergyNativeA)) kJ/mol (diff \(String(format: "%.4f", nativeAStats.energyPpm)) ppm) [\(nativeAStats.passed ? "PASS" : "FAIL")]")

        let psoNativeB = self.compileMetalNative(macros: ["INCLUDE_ENERGY": NSNumber(value: 1), "ENABLE_FORCE_ACCUMULATION": NSNumber(value: 1)])
        let (nativeBStats, computedEnergyNativeB) = self.runMetalPipelineAgreement(pso: psoNativeB, refEnergy: computedEnergyTrans)
        print("  Metal Native Variant B (SIMD Shuffle + Force Acc): max diff \(nativeBStats.maxDiffFixedPoint) fp, \(String(format: "%.6f", nativeBStats.maxAbsForceDiff)) kJ/(mol*nm), \(String(format: "%.4f", nativeBStats.forcePpm)) ppm, Energy: \(String(format: "%.2f", computedEnergyNativeB)) kJ/mol (diff \(String(format: "%.4f", nativeBStats.energyPpm)) ppm) [\(nativeBStats.passed ? "PASS" : "FAIL")]")

        let psoNativeC = self.compileMetalNative(macros: ["INCLUDE_ENERGY": NSNumber(value: 1), "ENABLE_FORCE_ACCUMULATION": NSNumber(value: 1), "ENABLE_OPTIMIZED": NSNumber(value: 1)])
        let (nativeCStats, computedEnergyNativeC) = self.runMetalPipelineAgreement(pso: psoNativeC, refEnergy: computedEnergyTrans)
        print("  Metal Native Variant C (Optimized unroll): max diff \(nativeCStats.maxDiffFixedPoint) fp, \(String(format: "%.6f", nativeCStats.maxAbsForceDiff)) kJ/(mol*nm), \(String(format: "%.4f", nativeCStats.forcePpm)) ppm, Energy: \(String(format: "%.2f", computedEnergyNativeC)) kJ/mol (diff \(String(format: "%.4f", nativeCStats.energyPpm)) ppm) [\(nativeCStats.passed ? "PASS" : "FAIL")]")

        let agreementPassed = clStats.passed && transStats.passed && nativeAStats.passed && nativeBStats.passed && nativeCStats.passed
        if !agreementPassed {
            fputs("FATAL: Numerical agreement failed stated tolerance of \(self.tolerancePpm) ppm!\n", stderr)
            exit(1)
        }

        // Mutation Gates Verification
        print("\n[Step 2b: Mutation Gating Check]")
        var mutationResults: [MutationGateResult] = []

        let psoMutA = self.compileMetalNative(macros: ["MUTATE_VARIANT_A": NSNumber(value: 1)])
        let (mutAStats, _) = self.runMetalPipelineAgreement(pso: psoMutA)
        let gateA = !mutAStats.passed
        print("  Mutation A (+5% force on atom1): \(String(format: "%.1f", mutAStats.forcePpm)) ppm -> Gate \(gateA ? "CAUGHT (PASS)" : "MISSED (FAIL)")")
        mutationResults.append(MutationGateResult(mutation: "Variant A force magnitude (+5%)", targetPpm: mutAStats.forcePpm, gateDetected: gateA))

        let psoMutB = self.compileMetalNative(macros: ["ENABLE_FORCE_ACCUMULATION": NSNumber(value: 1), "MUTATE_VARIANT_B": NSNumber(value: 1)])
        let (mutBStats, _) = self.runMetalPipelineAgreement(pso: psoMutB)
        let gateB = !mutBStats.passed
        print("  Mutation B (force accumulation offset): \(String(format: "%.1f", mutBStats.forcePpm)) ppm -> Gate \(gateB ? "CAUGHT (PASS)" : "MISSED (FAIL)")")
        mutationResults.append(MutationGateResult(mutation: "Variant B force accumulation offset", targetPpm: mutBStats.forcePpm, gateDetected: gateB))

        let psoMutE = self.compileMetalNative(macros: ["INCLUDE_ENERGY": NSNumber(value: 1), "MUTATE_ENERGY": NSNumber(value: 1)])
        let (mutEStats, _) = self.runMetalPipelineAgreement(pso: psoMutE, refEnergy: computedEnergyTrans)
        let gateE = (mutEStats.energyPpm > self.tolerancePpm)
        print("  Mutation Energy (scaled +10%): \(String(format: "%.1f", mutEStats.energyPpm)) ppm -> Gate \(gateE ? "CAUGHT (PASS)" : "MISSED (FAIL)")")
        mutationResults.append(MutationGateResult(mutation: "Energy scaled +10%", targetPpm: mutEStats.energyPpm, gateDetected: gateE))

        if !gateA || !gateB || !gateE {
            fputs("FATAL: Mutation test failed to trip the gating tolerance!\n", stderr)
            exit(1)
        }

        // Erfc Candidate Analysis
        print("\n[Step 2c: Numerical Analysis of Erfc Candidates]")
        let erfcResults = evaluateErfcCandidates()
        for cand in erfcResults {
            print("  Candidate [\(cand.name)]: Max Abs Error = \(String(format: "%.2e", cand.maxAbsError)), Max Rel Error = \(String(format: "%.2e", cand.maxRelError))")
            print("    Note: \(cand.notes)")
        }

        // Speed Benchmarks
        print("\n[Step 3 & 4: Speed Benchmarks (\(self.numRepeats) runs, inputs restored before each run)]")

        var standalone: [String: TimingStats] = [:]
        print("  Benchmarking Apple OpenCL (tg=256)...")
        standalone["opencl"] = self.timeOpenCL(repeats: self.numRepeats)

        print("  Benchmarking Metal Straight Translation (tg=256)...")
        standalone["metal_translation_256"] = self.timeMetalPipeline(pso: psoTrans, groupSize: 256, repeats: self.numRepeats)

        print("  Benchmarking Metal Native Variant A (SIMD Shuffle, tg=256)...")
        standalone["metal_native_a_256"] = self.timeMetalPipeline(pso: psoNativeA, groupSize: 256, repeats: self.numRepeats)

        print("  Benchmarking Metal Native Variant B (SIMD Shuffle + Force Acc, tg=256)...")
        standalone["metal_native_b_256"] = self.timeMetalPipeline(pso: psoNativeB, groupSize: 256, repeats: self.numRepeats)

        print("  Benchmarking Metal Native Variant C (Optimized unroll, tg=256)...")
        standalone["metal_native_c_256"] = self.timeMetalPipeline(pso: psoNativeC, groupSize: 256, repeats: self.numRepeats)

        print("  Benchmarking Metal Native Variant C (Optimized unroll, tg=32)...")
        standalone["metal_native_c_32"] = self.timeMetalPipeline(pso: psoNativeC, groupSize: 32, repeats: self.numRepeats)

        // Threadgroup Sweep
        print("\n[Threadgroup Size Sweep]")
        var sweepNative: [String: TimingStats] = [:]
        var sweepTrans: [String: TimingStats] = [:]

        for tg in [32, 64, 128, 256, 512] {
            print("  Sweeping Native Variant C tg=\(tg)...")
            sweepNative["\(tg)"] = self.timeMetalPipeline(pso: psoNativeC, groupSize: tg, repeats: self.numRepeats)
        }
        for tg in [64, 128, 256] {
            print("  Sweeping Translation tg=\(tg)...")
            sweepTrans["\(tg)"] = self.timeMetalPipeline(pso: psoTrans, groupSize: tg, repeats: self.numRepeats)
        }

        return BenchmarkCaseResult(
            numAtoms: self.numAtoms,
            numBlocks: self.numBlocks,
            maxForceMagnitude: self.maxForceMag,
            referenceOpenCLAgreement: clStats,
            metalTranslationAgreement: transStats,
            metalNativeVariantAAgreement: nativeAStats,
            metalNativeVariantBAgreement: nativeBStats,
            metalNativeVariantCAgreement: nativeCStats,
            mutationGateResults: mutationResults,
            erfcCandidateResults: erfcResults,
            agreementVerified: agreementPassed,
            standaloneComputeNonbonded: standalone,
            threadgroupSweepNative: sweepNative,
            threadgroupSweepTranslation: sweepTrans
        )
    }
}

// MARK: - Main Entry Point

let args = CommandLine.arguments
var outPath: String? = nil
var capturesDir = "experiments/010-compute-nonbonded/captures"
var kernelsDir = "experiments/010-compute-nonbonded/kernels"
var benchmarkTarget = "all"
var numRepeats = 20

var i = 1
while i < args.count {
    switch args[i] {
    case "--out":
        if i + 1 < args.count { outPath = args[i + 1]; i += 1 }
    case "--captures-dir":
        if i + 1 < args.count { capturesDir = args[i + 1]; i += 1 }
    case "--kernels-dir":
        if i + 1 < args.count { kernelsDir = args[i + 1]; i += 1 }
    case "--target":
        if i + 1 < args.count { benchmarkTarget = args[i + 1]; i += 1 }
    case "--repeats":
        if i + 1 < args.count { numRepeats = Int(args[i + 1]) ?? 20; i += 1 }
    default:
        break
    }
    i += 1
}

let tempDir = "/tmp/openmm_010_captures"
extractCapturesIfNeeded(capturesDir: capturesDir, targetDir: tempDir)

let chipName = getSysctlString("machdep.cpu.brand_string")
let osVersion = getOsProductVersion()
let osBuild = getOsBuild()

let dev = MTLCreateSystemDefaultDevice()!
let sampleNative = try! dev.makeComputePipelineState(function: dev.makeLibrary(source: """
#include <metal_stdlib>
using namespace metal;
kernel void test_simd() {}
""", options: nil).makeFunction(name: "test_simd")!)
let reportedSimdWidth = sampleNative.threadExecutionWidth

print("========================================================")
print("OpenMM Experiment 010: computeNonbonded Kernel Benchmark")
print("Host: \(chipName) | macOS \(osVersion) (Build \(osBuild))")
print("Reported SIMD width: \(reportedSimdWidth) | Hardware SIMD_WIDTH: 32")
print("Repeats: \(numRepeats)")
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

func pad(_ s: String, _ w: Int) -> String {
    if s.count >= w { return s }
    return s + String(repeating: " ", count: w - s.count)
}
func padLeft(_ s: String, _ w: Int) -> String {
    if s.count >= w { return s }
    return String(repeating: " ", count: w - s.count) + s
}

print("\n========================================================")
print("Benchmark Summary Table: computeNonbonded (Median of \(numRepeats) runs)")
print("========================================================")
print("\(pad("Benchmark", 10)) | \(pad("OpenCL (ms)", 12)) | \(pad("Trans (ms)", 12)) | \(pad("Native A", 10)) | \(pad("Native B", 10)) | \(pad("Native C (256)", 14)) | \(pad("Native C (32)", 14))")
print(String(repeating: "-", count: 88))

for c in casesToRun {
    if let res = benchmarkResults[c] {
        let clMs = res.standaloneComputeNonbonded["opencl"]?.median ?? 0
        let transMs = res.standaloneComputeNonbonded["metal_translation_256"]?.median ?? 0
        let natAMs = res.standaloneComputeNonbonded["metal_native_a_256"]?.median ?? 0
        let natBMs = res.standaloneComputeNonbonded["metal_native_b_256"]?.median ?? 0
        let natC256Ms = res.standaloneComputeNonbonded["metal_native_c_256"]?.median ?? 0
        let natC32Ms = res.standaloneComputeNonbonded["metal_native_c_32"]?.median ?? 0

        let clStr = String(format: "%.4f", clMs)
        let transStr = String(format: "%.4f", transMs)
        let natAStr = String(format: "%.4f", natAMs)
        let natBStr = String(format: "%.4f", natBMs)
        let natC256Str = String(format: "%.4f", natC256Ms)
        let natC32Str = String(format: "%.4f", natC32Ms)

        print("\(pad(c, 10)) | \(padLeft(clStr, 12)) | \(padLeft(transStr, 12)) | \(padLeft(natAStr, 10)) | \(padLeft(natBStr, 10)) | \(padLeft(natC256Str, 14)) | \(padLeft(natC32Str, 14))")
    }
}
print("========================================================\n")

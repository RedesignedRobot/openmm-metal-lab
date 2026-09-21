import Foundation
import Metal
import OpenCL
import Darwin

// MARK: - Types and Structures

struct InteractionPair: Hashable {
    let block: Int32
    let atom: UInt32
}

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

struct BenchmarkOutput: Codable {
    let chip: String
    let osVersion: String
    let osBuild: String
    let reportedSimdWidth: Int
    let kernelSimdWidth: Int
    let benchmarks: [String: BenchmarkCaseResult]
}

struct BenchmarkCaseResult: Codable {
    let numAtoms: Int
    let numBlocks: Int
    let referenceTiles: Int
    let referenceUniquePairs: Int
    let openclUniquePairs: Int
    let metalTranslationUniquePairs: Int
    let metalNativeUniquePairs: Int
    let agreementVerified: Bool
    let standaloneFindBlocks: [String: TimingStats]
    let threadgroupSweepNative: [String: TimingStats]
    let threadgroupSweepTranslation: [String: TimingStats]
    let wholeSequence: [String: TimingStats]
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
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sw_vers")
    process.arguments = ["-productVersion"]
    let pipe = Pipe()
    process.standardOutput = pipe
    do {
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
    } catch {
        return "unknown"
    }
}

func executeMetalCommandBuffer(_ cmd: MTLCommandBuffer, name: String, timeoutSeconds: Double = 10.0) {
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

func executeOpenCLWithTimeout(_ queue: cl_command_queue, name: String, timeoutSeconds: Double = 10.0) {
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

// MARK: - MSL Rewriter for 005-style Straight Translation

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

// MARK: - Benchmark Case Runner

class BenchmarkRunner {
    let name: String
    let capDir: String
    let kernelsDir: String
    let numRepeats: Int

    let meta: [String: Any]
    let numAtoms: Int
    let numBlocks: Int
    let numBlockSizes: Int
    let maxTiles: Int
    let startBlockIndex: UInt32 = 0
    let forceRebuild: Int32 = 1

    var box: [Float]
    var invBox: [Float]
    var boxVecX: [Float]
    var boxVecY: [Float]
    var boxVecZ: [Float]

    let posqData: Data
    let sortedBlocksData: Data
    let blockCenterData: Data
    let blockBoxData: Data
    let sortedCenterData: Data
    let sortedBoxData: Data
    let exclIndData: Data
    let exclRowData: Data
    let oldPosData: Data
    let rebuildData: Data
    let blockSizeRangeData: Data

    let refCountData: Data
    let refTilesData: Data
    let refAtomsData: Data
    let refCount: UInt32
    let refSet: Set<InteractionPair>

    let metalDevice: MTLDevice
    let metalQueue: MTLCommandQueue

    var clPlatform: cl_platform_id?
    var clDevice: cl_device_id?
    var clContext: cl_context?
    var clQueue: cl_command_queue?
    var clProgram: cl_program?

    init(name: String, capDir: String, kernelsDir: String, numRepeats: Int) {
        self.name = name
        self.capDir = capDir
        self.kernelsDir = kernelsDir
        self.numRepeats = numRepeats

        let metaData = try! Data(contentsOf: URL(fileURLWithPath: "\(capDir)/metadata.json"))
        self.meta = try! JSONSerialization.jsonObject(with: metaData) as! [String: Any]

        self.numAtoms = self.meta["numAtoms"] as! Int
        self.numBlocks = self.meta["numBlocksParam"] as! Int
        self.numBlockSizes = self.meta["numBlockSizes"] as! Int
        self.maxTiles = self.meta["maxTiles"] as! Int

        self.box = (self.meta["periodicBoxSize"] as! [Double]).map { Float($0) }
        self.invBox = (self.meta["invPeriodicBoxSize"] as! [Double]).map { Float($0) }
        self.boxVecX = (self.meta["periodicBoxVecX"] as! [Double]).map { Float($0) }
        self.boxVecY = (self.meta["periodicBoxVecY"] as! [Double]).map { Float($0) }
        self.boxVecZ = (self.meta["periodicBoxVecZ"] as! [Double]).map { Float($0) }

        self.posqData = try! Data(contentsOf: URL(fileURLWithPath: "\(capDir)/posq.bin"))
        self.sortedBlocksData = try! Data(contentsOf: URL(fileURLWithPath: "\(capDir)/sortedBlocks_after_sort.bin"))
        self.blockCenterData = try! Data(contentsOf: URL(fileURLWithPath: "\(capDir)/blockCenter_after_findBlockBounds.bin"))
        self.blockBoxData = try! Data(contentsOf: URL(fileURLWithPath: "\(capDir)/blockBoundingBox_after_findBlockBounds.bin"))
        self.sortedCenterData = try! Data(contentsOf: URL(fileURLWithPath: "\(capDir)/sortedBlockCenter_after_sortBoxData.bin"))
        self.sortedBoxData = try! Data(contentsOf: URL(fileURLWithPath: "\(capDir)/sortedBlockBoundingBox_after_sortBoxData.bin"))
        self.exclIndData = try! Data(contentsOf: URL(fileURLWithPath: "\(capDir)/exclusionIndices.bin"))
        self.exclRowData = try! Data(contentsOf: URL(fileURLWithPath: "\(capDir)/exclusionRowIndices.bin"))
        self.oldPosData = try! Data(contentsOf: URL(fileURLWithPath: "\(capDir)/oldPositions_after_sortBoxData.bin"))
        self.rebuildData = try! Data(contentsOf: URL(fileURLWithPath: "\(capDir)/rebuildNeighborList_after_sortBoxData.bin"))
        self.blockSizeRangeData = try! Data(contentsOf: URL(fileURLWithPath: "\(capDir)/blockSizeRange_after_findBlockBounds.bin"))

        let rCountData = try! Data(contentsOf: URL(fileURLWithPath: "\(capDir)/interactionCount_after_findBlocksWithInteractions.bin"))
        let rTilesData = try! Data(contentsOf: URL(fileURLWithPath: "\(capDir)/interactingTiles_after_findBlocksWithInteractions.bin"))
        let rAtomsData = try! Data(contentsOf: URL(fileURLWithPath: "\(capDir)/interactingAtoms_after_findBlocksWithInteractions.bin"))
        let rCount = rCountData.withUnsafeBytes { $0.load(as: UInt32.self) }

        let nAtoms = UInt32(self.numAtoms)
        var set = Set<InteractionPair>()
        rTilesData.withUnsafeBytes { rT in
            let tPtr = rT.bindMemory(to: Int32.self)
            rAtomsData.withUnsafeBytes { rA in
                let aPtr = rA.bindMemory(to: UInt32.self)
                for t in 0..<Int(rCount) {
                    let block = tPtr[t]
                    for k in 0..<32 {
                        let atom = aPtr[t * 32 + k]
                        if atom < nAtoms {
                            set.insert(InteractionPair(block: block, atom: atom))
                        }
                    }
                }
            }
        }
        self.refCountData = rCountData
        self.refTilesData = rTilesData
        self.refAtomsData = rAtomsData
        self.refCount = rCount
        self.refSet = set

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

        let kernelPrefix = (self.name == "apoa1rf" ? "findInteractingBlocks_rf" : "findInteractingBlocks_pme")
        let clSrcPath = "\(self.kernelsDir)/\(kernelPrefix).full.cl"
        let clSrc = try! String(contentsOfFile: clSrcPath, encoding: .utf8)
        var cStr: UnsafePointer<CChar>? = (clSrc as NSString).utf8String
        self.clProgram = clCreateProgramWithSource(self.clContext, 1, &cStr, nil, &err)
        clBuildProgram(self.clProgram, 1, &self.clDevice, "-cl-single-precision-constant", nil, nil)
    }

    func run() -> BenchmarkCaseResult {
        print("\n========================================================")
        print("Running benchmark case: \(self.name)")
        print("Atoms: \(self.numAtoms), Blocks: \(self.numBlocks), MaxTiles: \(self.maxTiles)")
        print("Captured OpenCL reference: \(self.refCount) tiles, \(self.refSet.count) unique interaction pairs")
        print("========================================================")

        // Step 2: Agreement verification
        let (clPairs, clTiles) = self.runOpenCLAgreement()
        let (transPairs, transTiles) = self.runMetalTranslationAgreement()
        let (nativePairs, nativeTiles) = self.runMetalNativeAgreement()

        let clDiff = self.refSet.symmetricDifference(clPairs)
        let transDiff = self.refSet.symmetricDifference(transPairs)
        let nativeDiff = self.refSet.symmetricDifference(nativePairs)

        print("\n[Step 2: Agreement Verification]")
        print("  Reference tiles: \(self.refCount), pairs: \(self.refSet.count)")
        print("  Apple OpenCL: tiles: \(clTiles), pairs: \(clPairs.count), symmetric diff: \(clDiff.count)")
        print("  Metal Translation: tiles: \(transTiles), pairs: \(transPairs.count), symmetric diff: \(transDiff.count)")
        print("  Metal Native: tiles: \(nativeTiles), pairs: \(nativePairs.count), symmetric diff: \(nativeDiff.count)")

        if !clDiff.isEmpty || !transDiff.isEmpty || !nativeDiff.isEmpty {
            fputs("FATAL: Interaction set mismatch! Gating check failed.\n", stderr)
            exit(1)
        }
        print("  SUCCESS: 100.000% set agreement across all four implementations (0 missing, 0 extra).")

        // Step 3 & 4: Performance Benchmarks
        print("\n[Step 3 & 4: Speed Benchmarks (\(self.numRepeats) runs, inputs restored before each run)]")

        // 1. Standalone findBlocksWithInteractions
        print("  Benchmarking standalone findBlocksWithInteractions...")
        let openclStats = self.timeOpenCLStandalone()
        print(String(format: "    OpenCL: median %.4f ms (min %.4f, max %.4f, IQR %.4f, std %.4f)",
                     openclStats.median, openclStats.min, openclStats.max, openclStats.iqr, openclStats.stddev))

        let transStats = self.timeMetalTranslationStandalone(groupSize: 256)
        print(String(format: "    Metal Translation (256): median %.4f ms (min %.4f, max %.4f, IQR %.4f, std %.4f)",
                     transStats.median, transStats.min, transStats.max, transStats.iqr, transStats.stddev))

        let nativeStats = self.timeMetalNativeStandalone(groupSize: 256)
        print(String(format: "    Metal Native (256): median %.4f ms (min %.4f, max %.4f, IQR %.4f, std %.4f)",
                     nativeStats.median, nativeStats.min, nativeStats.max, nativeStats.iqr, nativeStats.stddev))

        let speedupTrans = openclStats.median / transStats.median
        let speedupNative = openclStats.median / nativeStats.median
        let nativeOverTrans = transStats.median / nativeStats.median
        print(String(format: "    Speedup vs OpenCL: Metal Translation %.2fx, Metal Native %.2fx (Native vs Trans: %.2fx)",
                     speedupTrans, speedupNative, nativeOverTrans))

        // 2. Threadgroup size sweep
        print("  Sweeping threadgroup sizes (32, 64, 128, 256, 512)...")
        var nativeSweep: [String: TimingStats] = [:]
        var transSweep: [String: TimingStats] = [:]

        for size in [32, 64, 128, 256, 512] {
            let nStats = self.timeMetalNativeStandalone(groupSize: size)
            nativeSweep["\(size)"] = nStats
            let tStats = self.timeMetalTranslationStandalone(groupSize: size)
            transSweep["\(size)"] = tStats
            print(String(format: "    Size %4d: Native median %.4f ms | Trans median %.4f ms", size, nStats.median, tStats.median))
        }

        // 3. Whole sequence timing
        print("  Benchmarking full neighbour list sequence (findBlockBounds -> computeSortKeys -> sortBoxData -> findBlocks)...")
        let clSeqStats = self.timeOpenCLSequence()
        print(String(format: "    OpenCL Sequence: median %.4f ms (min %.4f, max %.4f, IQR %.4f)",
                     clSeqStats.median, clSeqStats.min, clSeqStats.max, clSeqStats.iqr))

        let transSeqStats = self.timeMetalSequence(useNativeFind: false)
        print(String(format: "    Metal Translation Sequence: median %.4f ms (min %.4f, max %.4f, IQR %.4f)",
                     transSeqStats.median, transSeqStats.min, transSeqStats.max, transSeqStats.iqr))

        let nativeSeqStats = self.timeMetalSequence(useNativeFind: true)
        print(String(format: "    Metal Native Sequence: median %.4f ms (min %.4f, max %.4f, IQR %.4f)",
                     nativeSeqStats.median, nativeSeqStats.min, nativeSeqStats.max, nativeSeqStats.iqr))

        let seqSpeedup = clSeqStats.median / nativeSeqStats.median
        print(String(format: "    Sequence Speedup vs OpenCL: %.2fx", seqSpeedup))

        return BenchmarkCaseResult(
            numAtoms: self.numAtoms,
            numBlocks: self.numBlocks,
            referenceTiles: Int(self.refCount),
            referenceUniquePairs: self.refSet.count,
            openclUniquePairs: clPairs.count,
            metalTranslationUniquePairs: transPairs.count,
            metalNativeUniquePairs: nativePairs.count,
            agreementVerified: true,
            standaloneFindBlocks: [
                "opencl": openclStats,
                "metal_translation_256": transStats,
                "metal_native_256": nativeStats
            ],
            threadgroupSweepNative: nativeSweep,
            threadgroupSweepTranslation: transSweep,
            wholeSequence: [
                "opencl": clSeqStats,
                "metal_translation": transSeqStats,
                "metal_native": nativeSeqStats
            ]
        )
    }

    // MARK: - OpenCL Kernels Execution

    func createOpenCLBuffers() -> (cl_mem, cl_mem, cl_mem, cl_mem, cl_mem, cl_mem, cl_mem, cl_mem, cl_mem, cl_mem, cl_mem, cl_mem, cl_mem) {
        var err: cl_int = 0
        var zeroCount: UInt32 = 0
        let clCountBuf = clCreateBuffer(self.clContext, cl_mem_flags(CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR), 8, &zeroCount, &err)!
        let clTilesBuf = clCreateBuffer(self.clContext, cl_mem_flags(CL_MEM_READ_WRITE), self.maxTiles * 4, nil, &err)!
        let clAtomsBuf = clCreateBuffer(self.clContext, cl_mem_flags(CL_MEM_READ_WRITE), self.maxTiles * 32 * 4, nil, &err)!

        let clPosqBuf = self.posqData.withUnsafeBytes { clCreateBuffer(self.clContext, cl_mem_flags(CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR), self.posqData.count, UnsafeMutableRawPointer(mutating: $0.baseAddress), &err)! }
        let clSortedBlocksBuf = self.sortedBlocksData.withUnsafeBytes { clCreateBuffer(self.clContext, cl_mem_flags(CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR), self.sortedBlocksData.count, UnsafeMutableRawPointer(mutating: $0.baseAddress), &err)! }
        let clBlockCenterBuf = self.blockCenterData.withUnsafeBytes { clCreateBuffer(self.clContext, cl_mem_flags(CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR), self.blockCenterData.count, UnsafeMutableRawPointer(mutating: $0.baseAddress), &err)! }
        let clBlockBoxBuf = self.blockBoxData.withUnsafeBytes { clCreateBuffer(self.clContext, cl_mem_flags(CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR), self.blockBoxData.count, UnsafeMutableRawPointer(mutating: $0.baseAddress), &err)! }
        let clSortedCenterBuf = self.sortedCenterData.withUnsafeBytes { clCreateBuffer(self.clContext, cl_mem_flags(CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR), self.sortedCenterData.count, UnsafeMutableRawPointer(mutating: $0.baseAddress), &err)! }
        let clSortedBoxBuf = self.sortedBoxData.withUnsafeBytes { clCreateBuffer(self.clContext, cl_mem_flags(CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR), self.sortedBoxData.count, UnsafeMutableRawPointer(mutating: $0.baseAddress), &err)! }
        let clExclIndBuf = self.exclIndData.withUnsafeBytes { clCreateBuffer(self.clContext, cl_mem_flags(CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR), self.exclIndData.count, UnsafeMutableRawPointer(mutating: $0.baseAddress), &err)! }
        let clExclRowBuf = self.exclRowData.withUnsafeBytes { clCreateBuffer(self.clContext, cl_mem_flags(CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR), self.exclRowData.count, UnsafeMutableRawPointer(mutating: $0.baseAddress), &err)! }
        let clOldPosBuf = self.oldPosData.withUnsafeBytes { clCreateBuffer(self.clContext, cl_mem_flags(CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR), self.oldPosData.count, UnsafeMutableRawPointer(mutating: $0.baseAddress), &err)! }
        let clRebuildBuf = self.rebuildData.withUnsafeBytes { clCreateBuffer(self.clContext, cl_mem_flags(CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR), self.rebuildData.count, UnsafeMutableRawPointer(mutating: $0.baseAddress), &err)! }

        return (clCountBuf, clTilesBuf, clAtomsBuf, clPosqBuf, clSortedBlocksBuf, clBlockCenterBuf, clBlockBoxBuf, clSortedCenterBuf, clSortedBoxBuf, clExclIndBuf, clExclRowBuf, clOldPosBuf, clRebuildBuf)
    }

    func runOpenCLAgreement() -> (Set<InteractionPair>, Int) {
        var err: cl_int = 0
        let kernel = clCreateKernel(self.clProgram, "findBlocksWithInteractions", &err)
        let (clCountBuf, clTilesBuf, clAtomsBuf, clPosqBuf, clSortedBlocksBuf, clBlockCenterBuf, clBlockBoxBuf, clSortedCenterBuf, clSortedBoxBuf, clExclIndBuf, clExclRowBuf, clOldPosBuf, clRebuildBuf) = self.createOpenCLBuffers()

        var maxTilesU = UInt32(self.maxTiles)
        var startBlockU = self.startBlockIndex
        var numBlocksU = UInt32(self.numBlocks)

        var countBufVar: cl_mem? = clCountBuf
        var tilesBufVar: cl_mem? = clTilesBuf
        var atomsBufVar: cl_mem? = clAtomsBuf
        var posqBufVar: cl_mem? = clPosqBuf
        var sortedBlocksVar: cl_mem? = clSortedBlocksBuf
        var sortedCenterVar: cl_mem? = clSortedCenterBuf
        var sortedBoxVar: cl_mem? = clSortedBoxBuf
        var exclIndVar: cl_mem? = clExclIndBuf
        var exclRowVar: cl_mem? = clExclRowBuf
        var oldPosVar: cl_mem? = clOldPosBuf
        var rebuildVar: cl_mem? = clRebuildBuf

        clSetKernelArg(kernel, 0, 16, &self.box)
        clSetKernelArg(kernel, 1, 16, &self.invBox)
        clSetKernelArg(kernel, 2, 16, &self.boxVecX)
        clSetKernelArg(kernel, 3, 16, &self.boxVecY)
        clSetKernelArg(kernel, 4, 16, &self.boxVecZ)
        clSetKernelArg(kernel, 5, MemoryLayout<cl_mem>.size, &countBufVar)
        clSetKernelArg(kernel, 6, MemoryLayout<cl_mem>.size, &tilesBufVar)
        clSetKernelArg(kernel, 7, MemoryLayout<cl_mem>.size, &atomsBufVar)
        clSetKernelArg(kernel, 8, MemoryLayout<cl_mem>.size, &posqBufVar)
        clSetKernelArg(kernel, 9, 4, &maxTilesU)
        clSetKernelArg(kernel, 10, 4, &startBlockU)
        clSetKernelArg(kernel, 11, 4, &numBlocksU)
        clSetKernelArg(kernel, 12, MemoryLayout<cl_mem>.size, &sortedBlocksVar)
        clSetKernelArg(kernel, 13, MemoryLayout<cl_mem>.size, &sortedCenterVar)
        clSetKernelArg(kernel, 14, MemoryLayout<cl_mem>.size, &sortedBoxVar)
        clSetKernelArg(kernel, 15, MemoryLayout<cl_mem>.size, &exclIndVar)
        clSetKernelArg(kernel, 16, MemoryLayout<cl_mem>.size, &exclRowVar)
        clSetKernelArg(kernel, 17, MemoryLayout<cl_mem>.size, &oldPosVar)
        clSetKernelArg(kernel, 18, MemoryLayout<cl_mem>.size, &rebuildVar)

        var gws = 15360
        var lws = 256
        clEnqueueNDRangeKernel(self.clQueue, kernel, 1, nil, &gws, &lws, 0, nil, nil)
        executeOpenCLWithTimeout(self.clQueue!, name: "OpenCL agreement run")

        var outCount: UInt32 = 0
        clEnqueueReadBuffer(self.clQueue, clCountBuf, cl_bool(CL_TRUE), 0, 4, &outCount, 0, nil, nil)
        var outTiles = [Int32](repeating: 0, count: Int(outCount))
        clEnqueueReadBuffer(self.clQueue, clTilesBuf, cl_bool(CL_TRUE), 0, Int(outCount) * 4, &outTiles, 0, nil, nil)
        var outAtoms = [UInt32](repeating: 0, count: Int(outCount) * 32)
        clEnqueueReadBuffer(self.clQueue, clAtomsBuf, cl_bool(CL_TRUE), 0, Int(outCount) * 32 * 4, &outAtoms, 0, nil, nil)

        var pairSet = Set<InteractionPair>()
        for t in 0..<Int(outCount) {
            let block = outTiles[t]
            for k in 0..<32 {
                let atom = outAtoms[t * 32 + k]
                if atom < UInt32(self.numAtoms) {
                    pairSet.insert(InteractionPair(block: block, atom: atom))
                }
            }
        }

        clReleaseKernel(kernel)
        clReleaseMemObject(clCountBuf)
        clReleaseMemObject(clTilesBuf)
        clReleaseMemObject(clAtomsBuf)
        clReleaseMemObject(clPosqBuf)
        clReleaseMemObject(clSortedBlocksBuf)
        clReleaseMemObject(clBlockCenterBuf)
        clReleaseMemObject(clBlockBoxBuf)
        clReleaseMemObject(clSortedCenterBuf)
        clReleaseMemObject(clSortedBoxBuf)
        clReleaseMemObject(clExclIndBuf)
        clReleaseMemObject(clExclRowBuf)
        clReleaseMemObject(clOldPosBuf)
        clReleaseMemObject(clRebuildBuf)

        return (pairSet, Int(outCount))
    }

    func timeOpenCLStandalone() -> TimingStats {
        var err: cl_int = 0
        let kernel = clCreateKernel(self.clProgram, "findBlocksWithInteractions", &err)
        let (clCountBuf, clTilesBuf, clAtomsBuf, clPosqBuf, clSortedBlocksBuf, clBlockCenterBuf, clBlockBoxBuf, clSortedCenterBuf, clSortedBoxBuf, clExclIndBuf, clExclRowBuf, clOldPosBuf, clRebuildBuf) = self.createOpenCLBuffers()

        var maxTilesU = UInt32(self.maxTiles)
        var startBlockU = self.startBlockIndex
        var numBlocksU = UInt32(self.numBlocks)

        var countBufVar: cl_mem? = clCountBuf
        var tilesBufVar: cl_mem? = clTilesBuf
        var atomsBufVar: cl_mem? = clAtomsBuf
        var posqBufVar: cl_mem? = clPosqBuf
        var sortedBlocksVar: cl_mem? = clSortedBlocksBuf
        var sortedCenterVar: cl_mem? = clSortedCenterBuf
        var sortedBoxVar: cl_mem? = clSortedBoxBuf
        var exclIndVar: cl_mem? = clExclIndBuf
        var exclRowVar: cl_mem? = clExclRowBuf
        var oldPosVar: cl_mem? = clOldPosBuf
        var rebuildVar: cl_mem? = clRebuildBuf

        clSetKernelArg(kernel, 0, 16, &self.box)
        clSetKernelArg(kernel, 1, 16, &self.invBox)
        clSetKernelArg(kernel, 2, 16, &self.boxVecX)
        clSetKernelArg(kernel, 3, 16, &self.boxVecY)
        clSetKernelArg(kernel, 4, 16, &self.boxVecZ)
        clSetKernelArg(kernel, 5, MemoryLayout<cl_mem>.size, &countBufVar)
        clSetKernelArg(kernel, 6, MemoryLayout<cl_mem>.size, &tilesBufVar)
        clSetKernelArg(kernel, 7, MemoryLayout<cl_mem>.size, &atomsBufVar)
        clSetKernelArg(kernel, 8, MemoryLayout<cl_mem>.size, &posqBufVar)
        clSetKernelArg(kernel, 9, 4, &maxTilesU)
        clSetKernelArg(kernel, 10, 4, &startBlockU)
        clSetKernelArg(kernel, 11, 4, &numBlocksU)
        clSetKernelArg(kernel, 12, MemoryLayout<cl_mem>.size, &sortedBlocksVar)
        clSetKernelArg(kernel, 13, MemoryLayout<cl_mem>.size, &sortedCenterVar)
        clSetKernelArg(kernel, 14, MemoryLayout<cl_mem>.size, &sortedBoxVar)
        clSetKernelArg(kernel, 15, MemoryLayout<cl_mem>.size, &exclIndVar)
        clSetKernelArg(kernel, 16, MemoryLayout<cl_mem>.size, &exclRowVar)
        clSetKernelArg(kernel, 17, MemoryLayout<cl_mem>.size, &oldPosVar)
        clSetKernelArg(kernel, 18, MemoryLayout<cl_mem>.size, &rebuildVar)

        var gws = 15360
        var lws = 256
        var zeroCount: UInt32 = 0

        // Warmup 3 iterations
        for _ in 0..<3 {
            clEnqueueWriteBuffer(self.clQueue, clCountBuf, cl_bool(CL_TRUE), 0, 4, &zeroCount, 0, nil, nil)
            clEnqueueNDRangeKernel(self.clQueue, kernel, 1, nil, &gws, &lws, 0, nil, nil)
            executeOpenCLWithTimeout(self.clQueue!, name: "OpenCL warmup")
        }

        var runs: [Double] = []
        for _ in 0..<self.numRepeats {
            // Restore inputs
            clEnqueueWriteBuffer(self.clQueue, clCountBuf, cl_bool(CL_TRUE), 0, 4, &zeroCount, 0, nil, nil)
            var rebuildVal: Int32 = 1
            clEnqueueWriteBuffer(self.clQueue, clRebuildBuf, cl_bool(CL_TRUE), 0, 4, &rebuildVal, 0, nil, nil)

            var ev: cl_event?
            clEnqueueNDRangeKernel(self.clQueue, kernel, 1, nil, &gws, &lws, 0, nil, &ev)
            executeOpenCLWithTimeout(self.clQueue!, name: "OpenCL timed run")

            var start: cl_ulong = 0
            var end: cl_ulong = 0
            clGetEventProfilingInfo(ev, cl_profiling_info(CL_PROFILING_COMMAND_START), MemoryLayout<cl_ulong>.size, &start, nil)
            clGetEventProfilingInfo(ev, cl_profiling_info(CL_PROFILING_COMMAND_END), MemoryLayout<cl_ulong>.size, &end, nil)
            clReleaseEvent(ev)

            let ms = Double(end - start) * (125.0 / 3.0) / 1e6
            runs.append(ms)
        }

        clReleaseKernel(kernel)
        clReleaseMemObject(clCountBuf)
        clReleaseMemObject(clTilesBuf)
        clReleaseMemObject(clAtomsBuf)
        clReleaseMemObject(clPosqBuf)
        clReleaseMemObject(clSortedBlocksBuf)
        clReleaseMemObject(clBlockCenterBuf)
        clReleaseMemObject(clBlockBoxBuf)
        clReleaseMemObject(clSortedCenterBuf)
        clReleaseMemObject(clSortedBoxBuf)
        clReleaseMemObject(clExclIndBuf)
        clReleaseMemObject(clExclRowBuf)
        clReleaseMemObject(clOldPosBuf)
        clReleaseMemObject(clRebuildBuf)

        return TimingStats(runs: runs)
    }

    func timeOpenCLSequence() -> TimingStats {
        var err: cl_int = 0
        let kBounds = clCreateKernel(self.clProgram, "findBlockBounds", &err)
        let kKeys = clCreateKernel(self.clProgram, "computeSortKeys", &err)
        let kBox = clCreateKernel(self.clProgram, "sortBoxData", &err)
        let kFind = clCreateKernel(self.clProgram, "findBlocksWithInteractions", &err)

        let (clCountBuf, clTilesBuf, clAtomsBuf, clPosqBuf, clSortedBlocksBuf, clBlockCenterBuf, clBlockBoxBuf, clSortedCenterBuf, clSortedBoxBuf, clExclIndBuf, clExclRowBuf, clOldPosBuf, clRebuildBuf) = self.createOpenCLBuffers()
        let clBlockSizeRangeBuf = self.blockSizeRangeData.withUnsafeBytes { clCreateBuffer(self.clContext, cl_mem_flags(CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR), self.blockSizeRangeData.count, UnsafeMutableRawPointer(mutating: $0.baseAddress), &err)! }

        var numAtomsI32 = Int32(self.numAtoms)
        var numBlocksParam = UInt32(self.numBlocks)
        var numBlockSizesParam = Int32(self.numBlockSizes)
        var maxTilesU = UInt32(self.maxTiles)
        var startBlockU = self.startBlockIndex
        var forceRebuildParam = self.forceRebuild

        var countBufVar: cl_mem? = clCountBuf
        var tilesBufVar: cl_mem? = clTilesBuf
        var atomsBufVar: cl_mem? = clAtomsBuf
        var posqBufVar: cl_mem? = clPosqBuf
        var blockCenterVar: cl_mem? = clBlockCenterBuf
        var blockBoxVar: cl_mem? = clBlockBoxBuf
        var sortedBlocksVar: cl_mem? = clSortedBlocksBuf
        var sortedCenterVar: cl_mem? = clSortedCenterBuf
        var sortedBoxVar: cl_mem? = clSortedBoxBuf
        var exclIndVar: cl_mem? = clExclIndBuf
        var exclRowVar: cl_mem? = clExclRowBuf
        var oldPosVar: cl_mem? = clOldPosBuf
        var rebuildVar: cl_mem? = clRebuildBuf
        var blockSizeRangeVar: cl_mem? = clBlockSizeRangeBuf

        // Set args for findBlockBounds
        clSetKernelArg(kBounds, 0, 4, &numAtomsI32)
        clSetKernelArg(kBounds, 1, 16, &self.box)
        clSetKernelArg(kBounds, 2, 16, &self.invBox)
        clSetKernelArg(kBounds, 3, 16, &self.boxVecX)
        clSetKernelArg(kBounds, 4, 16, &self.boxVecY)
        clSetKernelArg(kBounds, 5, 16, &self.boxVecZ)
        clSetKernelArg(kBounds, 6, MemoryLayout<cl_mem>.size, &posqBufVar)
        clSetKernelArg(kBounds, 7, MemoryLayout<cl_mem>.size, &blockCenterVar)
        clSetKernelArg(kBounds, 8, MemoryLayout<cl_mem>.size, &blockBoxVar)
        clSetKernelArg(kBounds, 9, MemoryLayout<cl_mem>.size, &rebuildVar)
        clSetKernelArg(kBounds, 10, MemoryLayout<cl_mem>.size, &blockSizeRangeVar)

        // Set args for computeSortKeys
        clSetKernelArg(kKeys, 0, MemoryLayout<cl_mem>.size, &blockBoxVar)
        clSetKernelArg(kKeys, 1, MemoryLayout<cl_mem>.size, &sortedBlocksVar)
        clSetKernelArg(kKeys, 2, MemoryLayout<cl_mem>.size, &blockSizeRangeVar)
        clSetKernelArg(kKeys, 3, 4, &numBlockSizesParam)

        // Set args for sortBoxData
        clSetKernelArg(kBox, 0, MemoryLayout<cl_mem>.size, &sortedBlocksVar)
        clSetKernelArg(kBox, 1, MemoryLayout<cl_mem>.size, &blockCenterVar)
        clSetKernelArg(kBox, 2, MemoryLayout<cl_mem>.size, &blockBoxVar)
        clSetKernelArg(kBox, 3, MemoryLayout<cl_mem>.size, &sortedCenterVar)
        clSetKernelArg(kBox, 4, MemoryLayout<cl_mem>.size, &sortedBoxVar)
        clSetKernelArg(kBox, 5, MemoryLayout<cl_mem>.size, &posqBufVar)
        clSetKernelArg(kBox, 6, MemoryLayout<cl_mem>.size, &oldPosVar)
        clSetKernelArg(kBox, 7, MemoryLayout<cl_mem>.size, &countBufVar)
        clSetKernelArg(kBox, 8, MemoryLayout<cl_mem>.size, &rebuildVar)
        clSetKernelArg(kBox, 9, 4, &forceRebuildParam)

        // Set args for findBlocksWithInteractions
        clSetKernelArg(kFind, 0, 16, &self.box)
        clSetKernelArg(kFind, 1, 16, &self.invBox)
        clSetKernelArg(kFind, 2, 16, &self.boxVecX)
        clSetKernelArg(kFind, 3, 16, &self.boxVecY)
        clSetKernelArg(kFind, 4, 16, &self.boxVecZ)
        clSetKernelArg(kFind, 5, MemoryLayout<cl_mem>.size, &countBufVar)
        clSetKernelArg(kFind, 6, MemoryLayout<cl_mem>.size, &tilesBufVar)
        clSetKernelArg(kFind, 7, MemoryLayout<cl_mem>.size, &atomsBufVar)
        clSetKernelArg(kFind, 8, MemoryLayout<cl_mem>.size, &posqBufVar)
        clSetKernelArg(kFind, 9, 4, &maxTilesU)
        clSetKernelArg(kFind, 10, 4, &startBlockU)
        clSetKernelArg(kFind, 11, 4, &numBlocksParam)
        clSetKernelArg(kFind, 12, MemoryLayout<cl_mem>.size, &sortedBlocksVar)
        clSetKernelArg(kFind, 13, MemoryLayout<cl_mem>.size, &sortedCenterVar)
        clSetKernelArg(kFind, 14, MemoryLayout<cl_mem>.size, &sortedBoxVar)
        clSetKernelArg(kFind, 15, MemoryLayout<cl_mem>.size, &exclIndVar)
        clSetKernelArg(kFind, 16, MemoryLayout<cl_mem>.size, &exclRowVar)
        clSetKernelArg(kFind, 17, MemoryLayout<cl_mem>.size, &oldPosVar)
        clSetKernelArg(kFind, 18, MemoryLayout<cl_mem>.size, &rebuildVar)

        var gwsBlocks = self.numBlocks
        var gwsAtoms = self.numAtoms
        var gwsFind = 15360
        var lwsFind = 256
        var zeroCount: UInt32 = 0

        // Warmup
        for _ in 0..<3 {
            clEnqueueWriteBuffer(self.clQueue, clCountBuf, cl_bool(CL_TRUE), 0, 4, &zeroCount, 0, nil, nil)
            clEnqueueNDRangeKernel(self.clQueue, kBounds, 1, nil, &gwsBlocks, nil, 0, nil, nil)
            clEnqueueNDRangeKernel(self.clQueue, kKeys, 1, nil, &gwsBlocks, nil, 0, nil, nil)
            clEnqueueNDRangeKernel(self.clQueue, kBox, 1, nil, &gwsAtoms, nil, 0, nil, nil)
            clEnqueueNDRangeKernel(self.clQueue, kFind, 1, nil, &gwsFind, &lwsFind, 0, nil, nil)
            executeOpenCLWithTimeout(self.clQueue!, name: "OpenCL sequence warmup")
        }

        var runs: [Double] = []
        for _ in 0..<self.numRepeats {
            // Restore inputs
            clEnqueueWriteBuffer(self.clQueue, clCountBuf, cl_bool(CL_TRUE), 0, 4, &zeroCount, 0, nil, nil)
            var rebuildVal: Int32 = 1
            clEnqueueWriteBuffer(self.clQueue, clRebuildBuf, cl_bool(CL_TRUE), 0, 4, &rebuildVal, 0, nil, nil)

            var ev1: cl_event?
            var ev2: cl_event?
            var ev3: cl_event?
            var ev4: cl_event?
            clEnqueueNDRangeKernel(self.clQueue, kBounds, 1, nil, &gwsBlocks, nil, 0, nil, &ev1)
            clEnqueueNDRangeKernel(self.clQueue, kKeys, 1, nil, &gwsBlocks, nil, 0, nil, &ev2)
            clEnqueueNDRangeKernel(self.clQueue, kBox, 1, nil, &gwsAtoms, nil, 0, nil, &ev3)
            clEnqueueNDRangeKernel(self.clQueue, kFind, 1, nil, &gwsFind, &lwsFind, 0, nil, &ev4)
            executeOpenCLWithTimeout(self.clQueue!, name: "OpenCL sequence timed run")

            var start1: cl_ulong = 0
            var end4: cl_ulong = 0
            clGetEventProfilingInfo(ev1, cl_profiling_info(CL_PROFILING_COMMAND_START), MemoryLayout<cl_ulong>.size, &start1, nil)
            clGetEventProfilingInfo(ev4, cl_profiling_info(CL_PROFILING_COMMAND_END), MemoryLayout<cl_ulong>.size, &end4, nil)

            clReleaseEvent(ev1)
            clReleaseEvent(ev2)
            clReleaseEvent(ev3)
            clReleaseEvent(ev4)

            let ms = Double(end4 - start1) * (125.0 / 3.0) / 1e6
            runs.append(ms)
        }

        clReleaseKernel(kBounds)
        clReleaseKernel(kKeys)
        clReleaseKernel(kBox)
        clReleaseKernel(kFind)

        clReleaseMemObject(clCountBuf)
        clReleaseMemObject(clTilesBuf)
        clReleaseMemObject(clAtomsBuf)
        clReleaseMemObject(clPosqBuf)
        clReleaseMemObject(clSortedBlocksBuf)
        clReleaseMemObject(clBlockCenterBuf)
        clReleaseMemObject(clBlockBoxBuf)
        clReleaseMemObject(clSortedCenterBuf)
        clReleaseMemObject(clSortedBoxBuf)
        clReleaseMemObject(clExclIndBuf)
        clReleaseMemObject(clExclRowBuf)
        clReleaseMemObject(clOldPosBuf)
        clReleaseMemObject(clRebuildBuf)
        clReleaseMemObject(clBlockSizeRangeBuf)

        return TimingStats(runs: runs)
    }

    // MARK: - Metal Kernels Execution

    func createMetalBuffers() -> (MTLBuffer, MTLBuffer, MTLBuffer, MTLBuffer, MTLBuffer, MTLBuffer, MTLBuffer, MTLBuffer, MTLBuffer, MTLBuffer, MTLBuffer, MTLBuffer, MTLBuffer, MTLBuffer) {
        let countBuf = self.metalDevice.makeBuffer(length: 8, options: .storageModeShared)!
        let tilesBuf = self.metalDevice.makeBuffer(length: self.maxTiles * 4, options: .storageModeShared)!
        let atomsBuf = self.metalDevice.makeBuffer(length: self.maxTiles * 32 * 4, options: .storageModeShared)!

        let posqBuf = self.metalDevice.makeBuffer(bytes: (self.posqData as NSData).bytes, length: self.posqData.count, options: .storageModeShared)!
        let sortedBlocksBuf = self.metalDevice.makeBuffer(bytes: (self.sortedBlocksData as NSData).bytes, length: self.sortedBlocksData.count, options: .storageModeShared)!
        let blockCenterBuf = self.metalDevice.makeBuffer(bytes: (self.blockCenterData as NSData).bytes, length: self.blockCenterData.count, options: .storageModeShared)!
        let blockBoxBuf = self.metalDevice.makeBuffer(bytes: (self.blockBoxData as NSData).bytes, length: self.blockBoxData.count, options: .storageModeShared)!
        let sortedCenterBuf = self.metalDevice.makeBuffer(bytes: (self.sortedCenterData as NSData).bytes, length: self.sortedCenterData.count, options: .storageModeShared)!
        let sortedBoxBuf = self.metalDevice.makeBuffer(bytes: (self.sortedBoxData as NSData).bytes, length: self.sortedBoxData.count, options: .storageModeShared)!
        let exclIndBuf = self.metalDevice.makeBuffer(bytes: (self.exclIndData as NSData).bytes, length: self.exclIndData.count, options: .storageModeShared)!
        let exclRowBuf = self.metalDevice.makeBuffer(bytes: (self.exclRowData as NSData).bytes, length: self.exclRowData.count, options: .storageModeShared)!
        let oldPosBuf = self.metalDevice.makeBuffer(bytes: (self.oldPosData as NSData).bytes, length: self.oldPosData.count, options: .storageModeShared)!
        let rebuildBuf = self.metalDevice.makeBuffer(bytes: (self.rebuildData as NSData).bytes, length: self.rebuildData.count, options: .storageModeShared)!
        let blockSizeRangeBuf = self.metalDevice.makeBuffer(bytes: (self.blockSizeRangeData as NSData).bytes, length: self.blockSizeRangeData.count, options: .storageModeShared)!

        return (countBuf, tilesBuf, atomsBuf, posqBuf, sortedBlocksBuf, blockCenterBuf, blockBoxBuf, sortedCenterBuf, sortedBoxBuf, exclIndBuf, exclRowBuf, oldPosBuf, rebuildBuf, blockSizeRangeBuf)
    }

    func compileMetalTranslationPipeline(groupSize: Int) -> (MTLLibrary, MTLComputePipelineState) {
        let prelude = try! String(contentsOfFile: "\(self.kernelsDir)/prelude.metal", encoding: .utf8)
        let kernelPrefix = (self.name == "apoa1rf" ? "findInteractingBlocks_rf" : "findInteractingBlocks_pme")
        let definesLines = try! String(contentsOfFile: "\(self.kernelsDir)/\(kernelPrefix).defines", encoding: .utf8)
        var definesStr = ""
        for line in definesLines.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: "\t")
            if parts.count >= 3 && parts[0] == "program" {
                if parts[1] == "GROUP_SIZE" {
                    definesStr += "#define GROUP_SIZE \(groupSize)\n"
                } else {
                    definesStr += "#define \(parts[1]) \(parts[2])\n"
                }
            }
        }
        let body = try! String(contentsOfFile: "\(self.kernelsDir)/\(kernelPrefix).body.cl", encoding: .utf8)
        let mslTrans = prelude + "\n" + definesStr + "\n" + rewriteVectorLiterals(source: rewriteKernelSignatures(source: body))

        let opts = MTLCompileOptions()
        opts.mathMode = .safe
        let lib = try! self.metalDevice.makeLibrary(source: mslTrans, options: opts)
        let pso = try! self.metalDevice.makeComputePipelineState(function: lib.makeFunction(name: "findBlocksWithInteractions")!)
        return (lib, pso)
    }

    func compileMetalNativePipeline(groupSize: Int) -> MTLComputePipelineState {
        let kernelPrefix = (self.name == "apoa1rf" ? "findInteractingBlocks_rf" : "findInteractingBlocks_pme")
        let definesLines = try! String(contentsOfFile: "\(self.kernelsDir)/\(kernelPrefix).defines", encoding: .utf8)
        var definesStr = ""
        for line in definesLines.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: "\t")
            if parts.count >= 3 && parts[0] == "program" {
                if parts[1] == "GROUP_SIZE" {
                    definesStr += "#define GROUP_SIZE \(groupSize)\n"
                } else {
                    definesStr += "#define \(parts[1]) \(parts[2])\n"
                }
            }
        }
        definesStr += "#define APPLY_PERIODIC_TO_DELTA(delta) delta.xyz -= floor(delta.xyz*invPeriodicBoxSize.xyz+0.5f)*periodicBoxSize.xyz;\n"
        definesStr += "#define APPLY_PERIODIC_TO_POS(pos) pos.xyz -= floor(pos.xyz*invPeriodicBoxSize.xyz)*periodicBoxSize.xyz;\n"
        definesStr += "#define APPLY_PERIODIC_TO_POS_WITH_CENTER(pos, center) {pos.x -= floor((pos.x-center.x)*invPeriodicBoxSize.x+0.5f)*periodicBoxSize.x; pos.y -= floor((pos.y-center.y)*invPeriodicBoxSize.y+0.5f)*periodicBoxSize.y; pos.z -= floor((pos.z-center.z)*invPeriodicBoxSize.z+0.5f)*periodicBoxSize.z;}\n"

        let nativeBody = try! String(contentsOfFile: "\(self.kernelsDir)/findInteractingBlocks_native.metal", encoding: .utf8)
        let src = definesStr + "\n" + nativeBody

        let opts = MTLCompileOptions()
        opts.mathMode = .safe
        let lib = try! self.metalDevice.makeLibrary(source: src, options: opts)
        return try! self.metalDevice.makeComputePipelineState(function: lib.makeFunction(name: "findBlocksWithInteractions_native")!)
    }

    func runMetalTranslationAgreement() -> (Set<InteractionPair>, Int) {
        let (_, pso) = self.compileMetalTranslationPipeline(groupSize: 256)
        let (countBuf, tilesBuf, atomsBuf, posqBuf, sortedBlocksBuf, _, _, sortedCenterBuf, sortedBoxBuf, exclIndBuf, exclRowBuf, oldPosBuf, rebuildBuf, _) = self.createMetalBuffers()

        var maxTilesU = UInt32(self.maxTiles)
        var startBlockU = self.startBlockIndex
        var numBlocksU = UInt32(self.numBlocks)

        memset(countBuf.contents(), 0, 8)

        let cmd = self.metalQueue.makeCommandBuffer()!
        let enc = cmd.makeComputeCommandEncoder()!
        enc.setComputePipelineState(pso)
        enc.setBytes(&self.box, length: 16, index: 0)
        enc.setBytes(&self.invBox, length: 16, index: 1)
        enc.setBytes(&self.boxVecX, length: 16, index: 2)
        enc.setBytes(&self.boxVecY, length: 16, index: 3)
        enc.setBytes(&self.boxVecZ, length: 16, index: 4)
        enc.setBuffer(countBuf, offset: 0, index: 5)
        enc.setBuffer(tilesBuf, offset: 0, index: 6)
        enc.setBuffer(atomsBuf, offset: 0, index: 7)
        enc.setBuffer(posqBuf, offset: 0, index: 8)
        enc.setBytes(&maxTilesU, length: 4, index: 9)
        enc.setBytes(&startBlockU, length: 4, index: 10)
        enc.setBytes(&numBlocksU, length: 4, index: 11)
        enc.setBuffer(sortedBlocksBuf, offset: 0, index: 12)
        enc.setBuffer(sortedCenterBuf, offset: 0, index: 13)
        enc.setBuffer(sortedBoxBuf, offset: 0, index: 14)
        enc.setBuffer(exclIndBuf, offset: 0, index: 15)
        enc.setBuffer(exclRowBuf, offset: 0, index: 16)
        enc.setBuffer(oldPosBuf, offset: 0, index: 17)
        enc.setBuffer(rebuildBuf, offset: 0, index: 18)

        enc.dispatchThreads(MTLSize(width: 15360, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        enc.endEncoding()
        executeMetalCommandBuffer(cmd, name: "Metal translation agreement run")

        let outCount = countBuf.contents().assumingMemoryBound(to: UInt32.self)[0]
        let outTiles = tilesBuf.contents().assumingMemoryBound(to: Int32.self)
        let outAtoms = atomsBuf.contents().assumingMemoryBound(to: UInt32.self)

        var pairSet = Set<InteractionPair>()
        for t in 0..<Int(outCount) {
            let block = outTiles[t]
            for k in 0..<32 {
                let atom = outAtoms[t * 32 + k]
                if atom < UInt32(self.numAtoms) {
                    pairSet.insert(InteractionPair(block: block, atom: atom))
                }
            }
        }

        return (pairSet, Int(outCount))
    }

    func runMetalNativeAgreement() -> (Set<InteractionPair>, Int) {
        let pso = self.compileMetalNativePipeline(groupSize: 256)
        let (countBuf, tilesBuf, atomsBuf, posqBuf, sortedBlocksBuf, _, _, sortedCenterBuf, sortedBoxBuf, exclIndBuf, exclRowBuf, oldPosBuf, rebuildBuf, _) = self.createMetalBuffers()

        var maxTilesU = UInt32(self.maxTiles)
        var startBlockU = self.startBlockIndex
        var numBlocksU = UInt32(self.numBlocks)

        memset(countBuf.contents(), 0, 8)

        let cmd = self.metalQueue.makeCommandBuffer()!
        let enc = cmd.makeComputeCommandEncoder()!
        enc.setComputePipelineState(pso)
        enc.setBytes(&self.box, length: 16, index: 0)
        enc.setBytes(&self.invBox, length: 16, index: 1)
        enc.setBytes(&self.boxVecX, length: 16, index: 2)
        enc.setBytes(&self.boxVecY, length: 16, index: 3)
        enc.setBytes(&self.boxVecZ, length: 16, index: 4)
        enc.setBuffer(countBuf, offset: 0, index: 5)
        enc.setBuffer(tilesBuf, offset: 0, index: 6)
        enc.setBuffer(atomsBuf, offset: 0, index: 7)
        enc.setBuffer(posqBuf, offset: 0, index: 8)
        enc.setBytes(&maxTilesU, length: 4, index: 9)
        enc.setBytes(&startBlockU, length: 4, index: 10)
        enc.setBytes(&numBlocksU, length: 4, index: 11)
        enc.setBuffer(sortedBlocksBuf, offset: 0, index: 12)
        enc.setBuffer(sortedCenterBuf, offset: 0, index: 13)
        enc.setBuffer(sortedBoxBuf, offset: 0, index: 14)
        enc.setBuffer(exclIndBuf, offset: 0, index: 15)
        enc.setBuffer(exclRowBuf, offset: 0, index: 16)
        enc.setBuffer(oldPosBuf, offset: 0, index: 17)
        enc.setBuffer(rebuildBuf, offset: 0, index: 18)

        enc.dispatchThreads(MTLSize(width: 15360, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        enc.endEncoding()
        executeMetalCommandBuffer(cmd, name: "Metal native agreement run")

        let outCount = countBuf.contents().assumingMemoryBound(to: UInt32.self)[0]
        let outTiles = tilesBuf.contents().assumingMemoryBound(to: Int32.self)
        let outAtoms = atomsBuf.contents().assumingMemoryBound(to: UInt32.self)

        var pairSet = Set<InteractionPair>()
        for t in 0..<Int(outCount) {
            let block = outTiles[t]
            for k in 0..<32 {
                let atom = outAtoms[t * 32 + k]
                if atom < UInt32(self.numAtoms) {
                    pairSet.insert(InteractionPair(block: block, atom: atom))
                }
            }
        }

        return (pairSet, Int(outCount))
    }

    func timeMetalTranslationStandalone(groupSize: Int) -> TimingStats {
        let (_, pso) = self.compileMetalTranslationPipeline(groupSize: groupSize)
        let (countBuf, tilesBuf, atomsBuf, posqBuf, sortedBlocksBuf, _, _, sortedCenterBuf, sortedBoxBuf, exclIndBuf, exclRowBuf, oldPosBuf, rebuildBuf, _) = self.createMetalBuffers()

        var maxTilesU = UInt32(self.maxTiles)
        var startBlockU = self.startBlockIndex
        var numBlocksU = UInt32(self.numBlocks)

        // Warmup
        for _ in 0..<3 {
            memset(countBuf.contents(), 0, 8)
            let cmd = self.metalQueue.makeCommandBuffer()!
            let enc = cmd.makeComputeCommandEncoder()!
            enc.setComputePipelineState(pso)
            enc.setBytes(&self.box, length: 16, index: 0)
            enc.setBytes(&self.invBox, length: 16, index: 1)
            enc.setBytes(&self.boxVecX, length: 16, index: 2)
            enc.setBytes(&self.boxVecY, length: 16, index: 3)
            enc.setBytes(&self.boxVecZ, length: 16, index: 4)
            enc.setBuffer(countBuf, offset: 0, index: 5)
            enc.setBuffer(tilesBuf, offset: 0, index: 6)
            enc.setBuffer(atomsBuf, offset: 0, index: 7)
            enc.setBuffer(posqBuf, offset: 0, index: 8)
            enc.setBytes(&maxTilesU, length: 4, index: 9)
            enc.setBytes(&startBlockU, length: 4, index: 10)
            enc.setBytes(&numBlocksU, length: 4, index: 11)
            enc.setBuffer(sortedBlocksBuf, offset: 0, index: 12)
            enc.setBuffer(sortedCenterBuf, offset: 0, index: 13)
            enc.setBuffer(sortedBoxBuf, offset: 0, index: 14)
            enc.setBuffer(exclIndBuf, offset: 0, index: 15)
            enc.setBuffer(exclRowBuf, offset: 0, index: 16)
            enc.setBuffer(oldPosBuf, offset: 0, index: 17)
            enc.setBuffer(rebuildBuf, offset: 0, index: 18)
            enc.dispatchThreads(MTLSize(width: 15360, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: groupSize, height: 1, depth: 1))
            enc.endEncoding()
            executeMetalCommandBuffer(cmd, name: "Metal translation warmup")
        }

        var runs: [Double] = []
        for _ in 0..<self.numRepeats {
            memset(countBuf.contents(), 0, 8)
            rebuildBuf.contents().assumingMemoryBound(to: Int32.self)[0] = 1

            let cmd = self.metalQueue.makeCommandBuffer()!
            let enc = cmd.makeComputeCommandEncoder()!
            enc.setComputePipelineState(pso)
            enc.setBytes(&self.box, length: 16, index: 0)
            enc.setBytes(&self.invBox, length: 16, index: 1)
            enc.setBytes(&self.boxVecX, length: 16, index: 2)
            enc.setBytes(&self.boxVecY, length: 16, index: 3)
            enc.setBytes(&self.boxVecZ, length: 16, index: 4)
            enc.setBuffer(countBuf, offset: 0, index: 5)
            enc.setBuffer(tilesBuf, offset: 0, index: 6)
            enc.setBuffer(atomsBuf, offset: 0, index: 7)
            enc.setBuffer(posqBuf, offset: 0, index: 8)
            enc.setBytes(&maxTilesU, length: 4, index: 9)
            enc.setBytes(&startBlockU, length: 4, index: 10)
            enc.setBytes(&numBlocksU, length: 4, index: 11)
            enc.setBuffer(sortedBlocksBuf, offset: 0, index: 12)
            enc.setBuffer(sortedCenterBuf, offset: 0, index: 13)
            enc.setBuffer(sortedBoxBuf, offset: 0, index: 14)
            enc.setBuffer(exclIndBuf, offset: 0, index: 15)
            enc.setBuffer(exclRowBuf, offset: 0, index: 16)
            enc.setBuffer(oldPosBuf, offset: 0, index: 17)
            enc.setBuffer(rebuildBuf, offset: 0, index: 18)
            enc.dispatchThreads(MTLSize(width: 15360, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: groupSize, height: 1, depth: 1))
            enc.endEncoding()
            executeMetalCommandBuffer(cmd, name: "Metal translation timed run")

            let ms = (cmd.gpuEndTime - cmd.gpuStartTime) * 1000.0
            runs.append(ms)
        }

        return TimingStats(runs: runs)
    }

    func timeMetalNativeStandalone(groupSize: Int) -> TimingStats {
        let pso = self.compileMetalNativePipeline(groupSize: groupSize)
        let (countBuf, tilesBuf, atomsBuf, posqBuf, sortedBlocksBuf, _, _, sortedCenterBuf, sortedBoxBuf, exclIndBuf, exclRowBuf, oldPosBuf, rebuildBuf, _) = self.createMetalBuffers()

        var maxTilesU = UInt32(self.maxTiles)
        var startBlockU = self.startBlockIndex
        var numBlocksU = UInt32(self.numBlocks)

        // Warmup
        for _ in 0..<3 {
            memset(countBuf.contents(), 0, 8)
            let cmd = self.metalQueue.makeCommandBuffer()!
            let enc = cmd.makeComputeCommandEncoder()!
            enc.setComputePipelineState(pso)
            enc.setBytes(&self.box, length: 16, index: 0)
            enc.setBytes(&self.invBox, length: 16, index: 1)
            enc.setBytes(&self.boxVecX, length: 16, index: 2)
            enc.setBytes(&self.boxVecY, length: 16, index: 3)
            enc.setBytes(&self.boxVecZ, length: 16, index: 4)
            enc.setBuffer(countBuf, offset: 0, index: 5)
            enc.setBuffer(tilesBuf, offset: 0, index: 6)
            enc.setBuffer(atomsBuf, offset: 0, index: 7)
            enc.setBuffer(posqBuf, offset: 0, index: 8)
            enc.setBytes(&maxTilesU, length: 4, index: 9)
            enc.setBytes(&startBlockU, length: 4, index: 10)
            enc.setBytes(&numBlocksU, length: 4, index: 11)
            enc.setBuffer(sortedBlocksBuf, offset: 0, index: 12)
            enc.setBuffer(sortedCenterBuf, offset: 0, index: 13)
            enc.setBuffer(sortedBoxBuf, offset: 0, index: 14)
            enc.setBuffer(exclIndBuf, offset: 0, index: 15)
            enc.setBuffer(exclRowBuf, offset: 0, index: 16)
            enc.setBuffer(oldPosBuf, offset: 0, index: 17)
            enc.setBuffer(rebuildBuf, offset: 0, index: 18)
            enc.dispatchThreads(MTLSize(width: 15360, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: groupSize, height: 1, depth: 1))
            enc.endEncoding()
            executeMetalCommandBuffer(cmd, name: "Metal native warmup")
        }

        var runs: [Double] = []
        for _ in 0..<self.numRepeats {
            memset(countBuf.contents(), 0, 8)
            rebuildBuf.contents().assumingMemoryBound(to: Int32.self)[0] = 1

            let cmd = self.metalQueue.makeCommandBuffer()!
            let enc = cmd.makeComputeCommandEncoder()!
            enc.setComputePipelineState(pso)
            enc.setBytes(&self.box, length: 16, index: 0)
            enc.setBytes(&self.invBox, length: 16, index: 1)
            enc.setBytes(&self.boxVecX, length: 16, index: 2)
            enc.setBytes(&self.boxVecY, length: 16, index: 3)
            enc.setBytes(&self.boxVecZ, length: 16, index: 4)
            enc.setBuffer(countBuf, offset: 0, index: 5)
            enc.setBuffer(tilesBuf, offset: 0, index: 6)
            enc.setBuffer(atomsBuf, offset: 0, index: 7)
            enc.setBuffer(posqBuf, offset: 0, index: 8)
            enc.setBytes(&maxTilesU, length: 4, index: 9)
            enc.setBytes(&startBlockU, length: 4, index: 10)
            enc.setBytes(&numBlocksU, length: 4, index: 11)
            enc.setBuffer(sortedBlocksBuf, offset: 0, index: 12)
            enc.setBuffer(sortedCenterBuf, offset: 0, index: 13)
            enc.setBuffer(sortedBoxBuf, offset: 0, index: 14)
            enc.setBuffer(exclIndBuf, offset: 0, index: 15)
            enc.setBuffer(exclRowBuf, offset: 0, index: 16)
            enc.setBuffer(oldPosBuf, offset: 0, index: 17)
            enc.setBuffer(rebuildBuf, offset: 0, index: 18)
            enc.dispatchThreads(MTLSize(width: 15360, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: groupSize, height: 1, depth: 1))
            enc.endEncoding()
            executeMetalCommandBuffer(cmd, name: "Metal native timed run")

            let ms = (cmd.gpuEndTime - cmd.gpuStartTime) * 1000.0
            runs.append(ms)
        }

        return TimingStats(runs: runs)
    }

    func timeMetalSequence(useNativeFind: Bool) -> TimingStats {
        let (libTrans, psoFindTrans) = self.compileMetalTranslationPipeline(groupSize: 256)
        let psoBounds = try! self.metalDevice.makeComputePipelineState(function: libTrans.makeFunction(name: "findBlockBounds")!)
        let psoKeys = try! self.metalDevice.makeComputePipelineState(function: libTrans.makeFunction(name: "computeSortKeys")!)
        let psoBox = try! self.metalDevice.makeComputePipelineState(function: libTrans.makeFunction(name: "sortBoxData")!)

        let psoFind = useNativeFind ? self.compileMetalNativePipeline(groupSize: 256) : psoFindTrans

        let (countBuf, tilesBuf, atomsBuf, posqBuf, sortedBlocksBuf, blockCenterBuf, blockBoxBuf, sortedCenterBuf, sortedBoxBuf, exclIndBuf, exclRowBuf, oldPosBuf, rebuildBuf, blockSizeRangeBuf) = self.createMetalBuffers()

        var numAtomsI32 = Int32(self.numAtoms)
        var numBlocksParam = UInt32(self.numBlocks)
        var numBlockSizesParam = Int32(self.numBlockSizes)
        var maxTilesU = UInt32(self.maxTiles)
        var startBlockU = self.startBlockIndex
        var forceRebuildParam = self.forceRebuild

        // Warmup
        for _ in 0..<3 {
            memset(countBuf.contents(), 0, 8)
            let cmd = self.metalQueue.makeCommandBuffer()!
            let enc = cmd.makeComputeCommandEncoder()!

            // 1. findBlockBounds
            enc.setComputePipelineState(psoBounds)
            enc.setBytes(&numAtomsI32, length: 4, index: 0)
            enc.setBytes(&self.box, length: 16, index: 1)
            enc.setBytes(&self.invBox, length: 16, index: 2)
            enc.setBytes(&self.boxVecX, length: 16, index: 3)
            enc.setBytes(&self.boxVecY, length: 16, index: 4)
            enc.setBytes(&self.boxVecZ, length: 16, index: 5)
            enc.setBuffer(posqBuf, offset: 0, index: 6)
            enc.setBuffer(blockCenterBuf, offset: 0, index: 7)
            enc.setBuffer(blockBoxBuf, offset: 0, index: 8)
            enc.setBuffer(rebuildBuf, offset: 0, index: 9)
            enc.setBuffer(blockSizeRangeBuf, offset: 0, index: 10)
            enc.dispatchThreads(MTLSize(width: self.numBlocks, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: min(64, psoBounds.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))

            // 2. computeSortKeys
            enc.setComputePipelineState(psoKeys)
            enc.setBuffer(blockBoxBuf, offset: 0, index: 0)
            enc.setBuffer(sortedBlocksBuf, offset: 0, index: 1)
            enc.setBuffer(blockSizeRangeBuf, offset: 0, index: 2)
            enc.setBytes(&numBlockSizesParam, length: 4, index: 3)
            enc.dispatchThreads(MTLSize(width: self.numBlocks, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: min(64, psoKeys.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))

            // 3. sortBoxData
            enc.setComputePipelineState(psoBox)
            enc.setBuffer(sortedBlocksBuf, offset: 0, index: 0)
            enc.setBuffer(blockCenterBuf, offset: 0, index: 1)
            enc.setBuffer(blockBoxBuf, offset: 0, index: 2)
            enc.setBuffer(sortedCenterBuf, offset: 0, index: 3)
            enc.setBuffer(sortedBoxBuf, offset: 0, index: 4)
            enc.setBuffer(posqBuf, offset: 0, index: 5)
            enc.setBuffer(oldPosBuf, offset: 0, index: 6)
            enc.setBuffer(countBuf, offset: 0, index: 7)
            enc.setBuffer(rebuildBuf, offset: 0, index: 8)
            enc.setBytes(&forceRebuildParam, length: 4, index: 9)
            enc.dispatchThreads(MTLSize(width: self.numAtoms, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: min(256, psoBox.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))

            // 4. findBlocksWithInteractions
            enc.setComputePipelineState(psoFind)
            enc.setBytes(&self.box, length: 16, index: 0)
            enc.setBytes(&self.invBox, length: 16, index: 1)
            enc.setBytes(&self.boxVecX, length: 16, index: 2)
            enc.setBytes(&self.boxVecY, length: 16, index: 3)
            enc.setBytes(&self.boxVecZ, length: 16, index: 4)
            enc.setBuffer(countBuf, offset: 0, index: 5)
            enc.setBuffer(tilesBuf, offset: 0, index: 6)
            enc.setBuffer(atomsBuf, offset: 0, index: 7)
            enc.setBuffer(posqBuf, offset: 0, index: 8)
            enc.setBytes(&maxTilesU, length: 4, index: 9)
            enc.setBytes(&startBlockU, length: 4, index: 10)
            enc.setBytes(&numBlocksParam, length: 4, index: 11)
            enc.setBuffer(sortedBlocksBuf, offset: 0, index: 12)
            enc.setBuffer(sortedCenterBuf, offset: 0, index: 13)
            enc.setBuffer(sortedBoxBuf, offset: 0, index: 14)
            enc.setBuffer(exclIndBuf, offset: 0, index: 15)
            enc.setBuffer(exclRowBuf, offset: 0, index: 16)
            enc.setBuffer(oldPosBuf, offset: 0, index: 17)
            enc.setBuffer(rebuildBuf, offset: 0, index: 18)
            enc.dispatchThreads(MTLSize(width: 15360, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))

            enc.endEncoding()
            executeMetalCommandBuffer(cmd, name: "Metal sequence warmup")
        }

        var runs: [Double] = []
        for _ in 0..<self.numRepeats {
            memset(countBuf.contents(), 0, 8)
            rebuildBuf.contents().assumingMemoryBound(to: Int32.self)[0] = 1

            let cmd = self.metalQueue.makeCommandBuffer()!
            let enc = cmd.makeComputeCommandEncoder()!

            // 1. findBlockBounds
            enc.setComputePipelineState(psoBounds)
            enc.setBytes(&numAtomsI32, length: 4, index: 0)
            enc.setBytes(&self.box, length: 16, index: 1)
            enc.setBytes(&self.invBox, length: 16, index: 2)
            enc.setBytes(&self.boxVecX, length: 16, index: 3)
            enc.setBytes(&self.boxVecY, length: 16, index: 4)
            enc.setBytes(&self.boxVecZ, length: 16, index: 5)
            enc.setBuffer(posqBuf, offset: 0, index: 6)
            enc.setBuffer(blockCenterBuf, offset: 0, index: 7)
            enc.setBuffer(blockBoxBuf, offset: 0, index: 8)
            enc.setBuffer(rebuildBuf, offset: 0, index: 9)
            enc.setBuffer(blockSizeRangeBuf, offset: 0, index: 10)
            enc.dispatchThreads(MTLSize(width: self.numBlocks, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: min(64, psoBounds.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))

            // 2. computeSortKeys
            enc.setComputePipelineState(psoKeys)
            enc.setBuffer(blockBoxBuf, offset: 0, index: 0)
            enc.setBuffer(sortedBlocksBuf, offset: 0, index: 1)
            enc.setBuffer(blockSizeRangeBuf, offset: 0, index: 2)
            enc.setBytes(&numBlockSizesParam, length: 4, index: 3)
            enc.dispatchThreads(MTLSize(width: self.numBlocks, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: min(64, psoKeys.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))

            // 3. sortBoxData
            enc.setComputePipelineState(psoBox)
            enc.setBuffer(sortedBlocksBuf, offset: 0, index: 0)
            enc.setBuffer(blockCenterBuf, offset: 0, index: 1)
            enc.setBuffer(blockBoxBuf, offset: 0, index: 2)
            enc.setBuffer(sortedCenterBuf, offset: 0, index: 3)
            enc.setBuffer(sortedBoxBuf, offset: 0, index: 4)
            enc.setBuffer(posqBuf, offset: 0, index: 5)
            enc.setBuffer(oldPosBuf, offset: 0, index: 6)
            enc.setBuffer(countBuf, offset: 0, index: 7)
            enc.setBuffer(rebuildBuf, offset: 0, index: 8)
            enc.setBytes(&forceRebuildParam, length: 4, index: 9)
            enc.dispatchThreads(MTLSize(width: self.numAtoms, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: min(256, psoBox.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))

            // 4. findBlocksWithInteractions
            enc.setComputePipelineState(psoFind)
            enc.setBytes(&self.box, length: 16, index: 0)
            enc.setBytes(&self.invBox, length: 16, index: 1)
            enc.setBytes(&self.boxVecX, length: 16, index: 2)
            enc.setBytes(&self.boxVecY, length: 16, index: 3)
            enc.setBytes(&self.boxVecZ, length: 16, index: 4)
            enc.setBuffer(countBuf, offset: 0, index: 5)
            enc.setBuffer(tilesBuf, offset: 0, index: 6)
            enc.setBuffer(atomsBuf, offset: 0, index: 7)
            enc.setBuffer(posqBuf, offset: 0, index: 8)
            enc.setBytes(&maxTilesU, length: 4, index: 9)
            enc.setBytes(&startBlockU, length: 4, index: 10)
            enc.setBytes(&numBlocksParam, length: 4, index: 11)
            enc.setBuffer(sortedBlocksBuf, offset: 0, index: 12)
            enc.setBuffer(sortedCenterBuf, offset: 0, index: 13)
            enc.setBuffer(sortedBoxBuf, offset: 0, index: 14)
            enc.setBuffer(exclIndBuf, offset: 0, index: 15)
            enc.setBuffer(exclRowBuf, offset: 0, index: 16)
            enc.setBuffer(oldPosBuf, offset: 0, index: 17)
            enc.setBuffer(rebuildBuf, offset: 0, index: 18)
            enc.dispatchThreads(MTLSize(width: 15360, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))

            enc.endEncoding()
            executeMetalCommandBuffer(cmd, name: "Metal sequence timed run")

            let ms = (cmd.gpuEndTime - cmd.gpuStartTime) * 1000.0
            runs.append(ms)
        }

        return TimingStats(runs: runs)
    }
}

// MARK: - Main Entry Point

let args = CommandLine.arguments
var outPath: String? = nil
var benchmarkTarget = "all"
var numRepeats = 20
var capturesDir = "experiments/009-neighbour-list/captures"
var kernelsDir = "experiments/009-neighbour-list/kernels"
var tempDir = "/tmp/openmm-009-captures"

var i = 1
while i < args.count {
    let arg = args[i]
    if arg == "--out" && i + 1 < args.count {
        outPath = args[i + 1]
        i += 2
    } else if arg == "--benchmark" && i + 1 < args.count {
        benchmarkTarget = args[i + 1]
        i += 2
    } else if arg == "--repeats" && i + 1 < args.count {
        numRepeats = Int(args[i + 1]) ?? 20
        i += 2
    } else if arg == "--captures-dir" && i + 1 < args.count {
        capturesDir = args[i + 1]
        i += 2
    } else if arg == "--kernels-dir" && i + 1 < args.count {
        kernelsDir = args[i + 1]
        i += 2
    } else {
        i += 1
    }
}

// Adjust relative paths if running inside directory
let fm = FileManager.default
if !fm.fileExists(atPath: capturesDir) && fm.fileExists(atPath: "captures") {
    capturesDir = "captures"
}
if !fm.fileExists(atPath: kernelsDir) && fm.fileExists(atPath: "kernels") {
    kernelsDir = "kernels"
}

// Ensure captures are extracted
extractCapturesIfNeeded(capturesDir: capturesDir, targetDir: tempDir)

let chipName = getSysctlString("machdep.cpu.brand_string")
let osVersion = getOsProductVersion()
let osBuild = getOsBuild()

let dev = MTLCreateSystemDefaultDevice()!
// Determine reported SIMD width from a representative pipeline
let sampleNative = try! dev.makeComputePipelineState(function: dev.makeLibrary(source: """
#include <metal_stdlib>
using namespace metal;
kernel void test_simd() {}
""", options: nil).makeFunction(name: "test_simd")!)
let reportedSimdWidth = sampleNative.threadExecutionWidth

print("========================================================")
print("OpenMM Experiment 009: Neighbour List Kernel Benchmark")
print("Host: \(chipName) | macOS \(osVersion) (Build \(osBuild))")
print("Reported SIMD width: \(reportedSimdWidth) | Assumed SIMD_WIDTH: 32")
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
print("Benchmark Summary Table (Standalone findBlocksWithInteractions)")
print("========================================================")
print("\(pad("Benchmark", 16)) | \(pad("Chip", 18)) | \(padLeft("OpenCL (ms)", 12)) | \(padLeft("Metal Trans (ms)", 18)) | \(padLeft("Metal Native (ms)", 18)) | \(padLeft("Pairs", 12))")
print(String(repeating: "-", count: 106))
for c in casesToRun {
    if let res = benchmarkResults[c] {
        let clMs = res.standaloneFindBlocks["opencl"]?.median ?? 0
        let transMs = res.standaloneFindBlocks["metal_translation_256"]?.median ?? 0
        let nativeMs = res.standaloneFindBlocks["metal_native_256"]?.median ?? 0
        let pairs = res.referenceUniquePairs
        let clStr = String(format: "%.4f", clMs)
        let transStr = String(format: "%.4f", transMs)
        let nativeStr = String(format: "%.4f", nativeMs)
        print("\(pad(c, 16)) | \(pad(chipName, 18)) | \(padLeft(clStr, 12)) | \(padLeft(transStr, 18)) | \(padLeft(nativeStr, 18)) | \(padLeft("\(pairs)", 12))")
    }
}
print("========================================================\n")

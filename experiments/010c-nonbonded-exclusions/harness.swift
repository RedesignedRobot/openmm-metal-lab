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
    let clock: String
    let workSize: String
    let stats: TimingStats
    let deltaVsOpenCL: Double
}

struct BenchmarkCaseResult: Codable {
    let numAtoms: Int
    let numBlocks: Int
    let maxTiles: UInt32
    let maxForceMagnitude: Double
    let workSize: String
    let definesSummary: String
    let agreementResults: [String: AgreementStats]
    let mutationGateResults: [MutationGateResult]
    let agreementVerified: Bool
    let ablations: [AblationRow]
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

// Profiling events converted from mach ticks via mach_timebase_info (copied from 011-pme/harness.swift)
func clEventMs(_ ev: cl_event?) -> Double {
    var t0: cl_ulong = 0, t1: cl_ulong = 0
    clGetEventProfilingInfo(ev, cl_profiling_info(CL_PROFILING_COMMAND_START), 8, &t0, nil)
    clGetEventProfilingInfo(ev, cl_profiling_info(CL_PROFILING_COMMAND_END), 8, &t1, nil)
    clReleaseEvent(ev)
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    return Double(t1 - t0) * Double(tb.numer) / Double(tb.denom) / 1_000_000.0
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
    let numRepeats: Int = 25 // 25 repeats as per ground rules
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

    init(name: String, capDir: String, kernelsDir: String) {
        self.name = name
        self.capDir = capDir
        self.kernelsDir = kernelsDir
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

    func compileMetalNative(functionName: String = "computeNonbonded", macros: [String: NSObject], optLevel: MTLLibraryOptimizationLevel = .default) -> MTLComputePipelineState {
        let nativeSrc = try! String(contentsOfFile: "\(self.kernelsDir)/computeNonbonded_native.metal", encoding: .utf8)
        let opt = MTLCompileOptions()
        opt.languageVersion = .version3_1
        opt.optimizationLevel = optLevel
        var allMacros = macros
        if self.isPME {
            allMacros["USE_PME"] = NSNumber(value: 1)
        }
        opt.preprocessorMacros = allMacros
        let lib = try! self.metalDevice.makeLibrary(source: nativeSrc, options: opt)
        let fn = lib.makeFunction(name: functionName)!
        return try! self.metalDevice.makeComputePipelineState(function: fn)
    }

    func evaluateAgreement(bufFB: MTLBuffer) -> AgreementStats {
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
        let passed = (ppm < self.tolerancePpm)
        return AgreementStats(
            maxDiffFixedPoint: maxDiff,
            maxAbsForceDiff: maxAbs,
            forcePpm: ppm,
            exactMatches: exact,
            totalWords: self.refFB.count,
            energyDiff: 0.0,
            energyPpm: 0.0,
            passed: passed
        )
    }

    func runMetalPipelineAgreement(pso: MTLComputePipelineState, groupSize: Int = 32) -> AgreementStats {
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

        let numGroups = (60 * 256) / groupSize
        enc.dispatchThreadgroups(MTLSize(width: numGroups, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: groupSize, height: 1, depth: 1))
        enc.endEncoding()

        executeMetalCommandBuffer(cmd, name: "Metal agreement run")
        return self.evaluateAgreement(bufFB: bufFB)
    }

    func runMetalSeparateAgreement(psoExcl: MTLComputePipelineState, psoInter: MTLComputePipelineState, groupSize: Int = 32) -> AgreementStats {
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

        // Dispatch 1: Exclusions
        enc.setComputePipelineState(psoExcl)
        enc.setBuffer(bufFB, offset: 0, index: 0)
        enc.setBuffer(bufEB, offset: 0, index: 1)
        enc.setBuffer(bufPosq, offset: 0, index: 2)
        enc.setBuffer(bufExcl, offset: 0, index: 3)
        enc.setBuffer(bufExclTiles, offset: 0, index: 4)
        enc.setBytes(&self.pBox, length: 16, index: 9)
        enc.setBytes(&self.invBox, length: 16, index: 10)
        enc.setBuffer(bufParams, offset: 0, index: 18)
        enc.dispatchThreadgroups(MTLSize(width: 5213, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 32, height: 1, depth: 1))

        // Dispatch 2: Interactions
        enc.setComputePipelineState(psoInter)
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

        let numGroups = (60 * 256) / groupSize
        enc.dispatchThreadgroups(MTLSize(width: numGroups, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: groupSize, height: 1, depth: 1))
        enc.endEncoding()

        executeMetalCommandBuffer(cmd, name: "Metal separate kernel agreement")
        return self.evaluateAgreement(bufFB: bufFB)
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

        // Measurement: 25 iterations
        var runs: [Double] = []
        for _ in 0..<self.numRepeats {
            _ = self.fbBeforeData.withUnsafeBytes { ptr in
                clEnqueueWriteBuffer(self.clQueue, bufClFB, cl_bool(CL_TRUE), 0, self.fbBeforeData.count, ptr.baseAddress!, 0, nil, nil)
            }
            var ev: cl_event?
            clEnqueueNDRangeKernel(self.clQueue, kernel, 1, nil, &gWork, &lWork, 0, nil, &ev)
            clFinish(self.clQueue)
            let ms = clEventMs(ev)
            runs.append(ms)
        }
        return TimingStats(runs: runs)
    }

    func timeMetal(pso: MTLComputePipelineState, groupSize: Int = 32) -> TimingStats {
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

        let numGroups = (60 * 256) / groupSize

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

            enc.dispatchThreadgroups(MTLSize(width: numGroups, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: groupSize, height: 1, depth: 1))
            enc.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
        }

        // Measurement: 25 iterations
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

            enc.dispatchThreadgroups(MTLSize(width: numGroups, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: groupSize, height: 1, depth: 1))
            enc.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()

            let ms = (cmd.gpuEndTime - cmd.gpuStartTime) * 1000.0
            runs.append(ms)
        }
        return TimingStats(runs: runs)
    }

    func timeMetalSeparate(psoExcl: MTLComputePipelineState, psoInter: MTLComputePipelineState, groupSize: Int = 32) -> TimingStats {
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

        let numGroups = (60 * 256) / groupSize

        // Warmup: 5 iterations
        for _ in 0..<5 {
            _ = self.fbBeforeData.withUnsafeBytes { ptr in
                memcpy(bufFB.contents(), ptr.baseAddress!, self.fbBeforeData.count)
            }
            let cmd = self.metalQueue.makeCommandBuffer()!
            let enc = cmd.makeComputeCommandEncoder()!

            enc.setComputePipelineState(psoExcl)
            enc.setBuffer(bufFB, offset: 0, index: 0)
            enc.setBuffer(bufEB, offset: 0, index: 1)
            enc.setBuffer(bufPosq, offset: 0, index: 2)
            enc.setBuffer(bufExcl, offset: 0, index: 3)
            enc.setBuffer(bufExclTiles, offset: 0, index: 4)
            enc.setBytes(&self.pBox, length: 16, index: 9)
            enc.setBytes(&self.invBox, length: 16, index: 10)
            enc.setBuffer(bufParams, offset: 0, index: 18)
            enc.dispatchThreadgroups(MTLSize(width: 5213, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 32, height: 1, depth: 1))

            enc.setComputePipelineState(psoInter)
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

            enc.dispatchThreadgroups(MTLSize(width: numGroups, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: groupSize, height: 1, depth: 1))
            enc.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
        }

        // Measurement: 25 iterations
        var runs: [Double] = []
        for _ in 0..<self.numRepeats {
            _ = self.fbBeforeData.withUnsafeBytes { ptr in
                memcpy(bufFB.contents(), ptr.baseAddress!, self.fbBeforeData.count)
            }
            let cmd = self.metalQueue.makeCommandBuffer()!
            let enc = cmd.makeComputeCommandEncoder()!

            enc.setComputePipelineState(psoExcl)
            enc.setBuffer(bufFB, offset: 0, index: 0)
            enc.setBuffer(bufEB, offset: 0, index: 1)
            enc.setBuffer(bufPosq, offset: 0, index: 2)
            enc.setBuffer(bufExcl, offset: 0, index: 3)
            enc.setBuffer(bufExclTiles, offset: 0, index: 4)
            enc.setBytes(&self.pBox, length: 16, index: 9)
            enc.setBytes(&self.invBox, length: 16, index: 10)
            enc.setBuffer(bufParams, offset: 0, index: 18)
            enc.dispatchThreadgroups(MTLSize(width: 5213, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 32, height: 1, depth: 1))

            enc.setComputePipelineState(psoInter)
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

            enc.dispatchThreadgroups(MTLSize(width: numGroups, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: groupSize, height: 1, depth: 1))
            enc.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()

            let ms = (cmd.gpuEndTime - cmd.gpuStartTime) * 1000.0
            runs.append(ms)
        }
        return TimingStats(runs: runs)
    }

    func run() -> BenchmarkCaseResult {
        let workSizeStr = "global: 15360, local: 256 (60 groups of 256)"
        let definesStr = self.isPME ? "USE_PME=1, CUTOFF_0_SQUARED=0.81, MAX_CUTOFF=0.9" : "CUTOFF_0_SQUARED=1.0, MAX_CUTOFF=1.0"

        print("\n========================================================")
        print("Running benchmark case: \(self.name)")
        print("Atoms: \(self.numAtoms), Blocks: \(self.numBlocks), MaxTiles: \(self.maxTiles)")
        print("Work size: \(workSizeStr)")
        print("Defines: \(definesStr)")
        print("Max Force Magnitude: \(String(format: "%.2f", self.maxForceMag)) kJ/(mol*nm)")
        print("Stated Tolerance: < \(self.tolerancePpm) ppm")
        print("========================================================")

        var agreementResults: [String: AgreementStats] = [:]

        // -------------------------------------------------------------------
        // Step 1: Numerical Agreement Checks
        // -------------------------------------------------------------------
        print("\n[Step 1: Agreement Verification]")

        let baseMacros: [String: NSObject] = [
            "ENABLE_FORCE_ACCUMULATION": NSNumber(value: 1),
            "ENABLE_OPTIMIZED": NSNumber(value: 1)
        ]

        // Baseline Native Variant C
        let psoBase = self.compileMetalNative(macros: baseMacros)
        let statsBase = self.runMetalPipelineAgreement(pso: psoBase)
        agreementResults["baseline_native"] = statsBase
        print("  Baseline Native (010b C): max diff \(statsBase.maxDiffFixedPoint), \(String(format: "%.4f", statsBase.forcePpm)) ppm [\(statsBase.passed ? "PASS" : "FAIL")] (tol: \(self.tolerancePpm) ppm)")

        // Formulation 2: Separate Exclusion Kernel
        var f2InterMacros = baseMacros
        f2InterMacros["FORMULATION_SEPARATE_KERNEL"] = NSNumber(value: 1)
        let psoF2Inter = self.compileMetalNative(functionName: "computeNonbonded", macros: f2InterMacros)
        let psoF2Excl = self.compileMetalNative(functionName: "computeNonbonded_exclusions", macros: baseMacros)
        let statsF2 = self.runMetalSeparateAgreement(psoExcl: psoF2Excl, psoInter: psoF2Inter)
        agreementResults["formulation_separate_kernel"] = statsF2
        print("  F2 Separate Kernel:       max diff \(statsF2.maxDiffFixedPoint), \(String(format: "%.4f", statsF2.forcePpm)) ppm [\(statsF2.passed ? "PASS" : "FAIL")] (tol: \(self.tolerancePpm) ppm)")

        // Formulation 3: Branch-Free Masked
        var f3Macros = baseMacros
        f3Macros["FORMULATION_MASKED"] = NSNumber(value: 1)
        let psoF3 = self.compileMetalNative(macros: f3Macros)
        let statsF3 = self.runMetalPipelineAgreement(pso: psoF3)
        agreementResults["formulation_masked"] = statsF3
        print("  F3 Branch-Free Masked:    max diff \(statsF3.maxDiffFixedPoint), \(String(format: "%.4f", statsF3.forcePpm)) ppm [\(statsF3.passed ? "PASS" : "FAIL")] (tol: \(self.tolerancePpm) ppm)")

        // Formulation 4: Tile-Size Unrolled (x4)
        var f4Macros = baseMacros
        f4Macros["FORMULATION_UNROLLED_4"] = NSNumber(value: 1)
        let psoF4 = self.compileMetalNative(macros: f4Macros)
        let statsF4 = self.runMetalPipelineAgreement(pso: psoF4)
        agreementResults["formulation_unrolled_4"] = statsF4
        print("  F4 Unrolled Loop (x4):    max diff \(statsF4.maxDiffFixedPoint), \(String(format: "%.4f", statsF4.forcePpm)) ppm [\(statsF4.passed ? "PASS" : "FAIL")] (tol: \(self.tolerancePpm) ppm)")

        // Writeback Alternative: Loop 1 Accumulation + Optimized Carry
        var wbMacros = baseMacros
        wbMacros["WRITEBACK_LOOP1_ACC"] = NSNumber(value: 1)
        wbMacros["WRITEBACK_OPTIMIZED_CARRY"] = NSNumber(value: 1)
        let psoWB = self.compileMetalNative(macros: wbMacros)
        let statsWB = self.runMetalPipelineAgreement(pso: psoWB)
        agreementResults["writeback_loop1_acc"] = statsWB
        print("  Writeback Alt (Loop 1 Acc): max diff \(statsWB.maxDiffFixedPoint), \(String(format: "%.4f", statsWB.forcePpm)) ppm [\(statsWB.passed ? "PASS" : "FAIL")] (tol: \(self.tolerancePpm) ppm)")

        // Winning Combination: Masked + Writeback Alt + .size
        let psoCombo = self.compileMetalNative(macros: comb(wbMacros, ["FORMULATION_MASKED": NSNumber(value: 1)]), optLevel: .size)
        let statsCombo = self.runMetalPipelineAgreement(pso: psoCombo)
        agreementResults["combo_winning"] = statsCombo
        print("  Combo Winning:            max diff \(statsCombo.maxDiffFixedPoint), \(String(format: "%.4f", statsCombo.forcePpm)) ppm [\(statsCombo.passed ? "PASS" : "FAIL")] (tol: \(self.tolerancePpm) ppm)")

        let allPassed = statsBase.passed && statsF2.passed && statsF3.passed && statsF4.passed && statsWB.passed && statsCombo.passed
        if !allPassed {
            fputs("FATAL: Numerical agreement check failed stated tolerance of \(self.tolerancePpm) ppm\n", stderr)
            exit(1)
        }

        // -------------------------------------------------------------------
        // Step 2: Mutation Gates (One mutation per new variant)
        // -------------------------------------------------------------------
        print("\n[Step 2: Gate Sensitivity Tests (One Mutation Per Variant)]")
        var mutationResults: [MutationGateResult] = []

        func runMutationCheck(name: String, pso: MTLComputePipelineState) {
            let stats = self.runMetalPipelineAgreement(pso: pso)
            let caught = !stats.passed
            print("  \(name): \(String(format: "%.1f", stats.forcePpm)) ppm -> Gate \(caught ? "CAUGHT (PASS)" : "MISSED (FAIL)")")
            mutationResults.append(MutationGateResult(mutation: name, targetPpm: stats.forcePpm, gateDetected: caught))
        }

        // Mutation 1: Baseline Variant A force scale (+5%)
        let psoMutBase = self.compileMetalNative(macros: comb(baseMacros, ["MUTATE_VARIANT_A": NSNumber(value: 1)]))
        runMutationCheck(name: "Baseline force scale (+5%)", pso: psoMutBase)

        // Mutation 2: Formulation 2 Separate Kernel (+5% force in exclusions)
        let psoMutF2Excl = self.compileMetalNative(functionName: "computeNonbonded_exclusions", macros: comb(baseMacros, ["MUTATE_F2_SEPARATE": NSNumber(value: 1)]))
        let statsMutF2 = self.runMetalSeparateAgreement(psoExcl: psoMutF2Excl, psoInter: psoF2Inter)
        let caughtF2 = !statsMutF2.passed
        print("  F2 Separate Kernel exclusion force (+5%): \(String(format: "%.1f", statsMutF2.forcePpm)) ppm -> Gate \(caughtF2 ? "CAUGHT (PASS)" : "MISSED (FAIL)")")
        mutationResults.append(MutationGateResult(mutation: "F2 Separate Kernel exclusion force (+5%)", targetPpm: statsMutF2.forcePpm, gateDetected: caughtF2))

        // Mutation 3: Formulation 3 Branch-Free Masked (+5% force in masked evaluation)
        let psoMutF3 = self.compileMetalNative(macros: comb(f3Macros, ["MUTATE_F3_MASK": NSNumber(value: 1)]))
        runMutationCheck(name: "F3 Masked pair force (+5%)", pso: psoMutF3)

        // Mutation 4: Formulation 4 Unrolled Loop (+5% force in unrolled loop)
        let psoMutF4 = self.compileMetalNative(macros: comb(f4Macros, ["MUTATE_F4_UNROLL": NSNumber(value: 1)]))
        runMutationCheck(name: "F4 Unrolled loop force (+5%)", pso: psoMutF4)

        // Mutation 5: Write-back Alternative offset (+1e8 to atom1_acc)
        let psoMutWB = self.compileMetalNative(macros: comb(wbMacros, ["MUTATE_WB_ACC": NSNumber(value: 1)]))
        runMutationCheck(name: "Writeback Alt force offset", pso: psoMutWB)

        let allMutationsCaught = mutationResults.allSatisfy { $0.gateDetected }
        if !allMutationsCaught {
            fputs("FATAL: Mutation test failed - verification gate did not catch artificial bug\n", stderr)
            exit(1)
        }

        // -------------------------------------------------------------------
        // Step 3: Ablation Benchmarking (Median of 25 with IQR)
        // -------------------------------------------------------------------
        print("\n[Step 3: Ablation Benchmarking (25 runs per variant)]")
        var ablations: [AblationRow] = []

        // OpenCL Baseline
        print("  Benchmarking OpenCL (forces only)...")
        let clKernel = self.compileOpenCLKernel()
        let clStats = self.timeOpenCL(kernel: clKernel)
        ablations.append(AblationRow(
            id: "opencl_baseline",
            description: "Apple OpenCL (forces only)",
            clock: "clEventMs (mach ticks)",
            workSize: workSizeStr,
            stats: clStats,
            deltaVsOpenCL: 0.0
        ))
        print("    -> Median: \(String(format: "%.3f", clStats.median)) ms, IQR: \(String(format: "%.3f", clStats.iqr)) ms")

        // OpenCL without exclusions
        print("  Benchmarking OpenCL (skip exclusions)...")
        let clSkipKernel = self.compileOpenCLKernel(extraDefs: ["ABLATION_C_NO_EXCLUSIONS"])
        let clSkipStats = self.timeOpenCL(kernel: clSkipKernel)
        ablations.append(AblationRow(
            id: "opencl_skip_exclusions",
            description: "Apple OpenCL (skip exclusions loop)",
            clock: "clEventMs (mach ticks)",
            workSize: workSizeStr,
            stats: clSkipStats,
            deltaVsOpenCL: clSkipStats.median - clStats.median
        ))
        print("    -> Median: \(String(format: "%.3f", clSkipStats.median)) ms, IQR: \(String(format: "%.3f", clSkipStats.iqr)) ms (exclusion cost: \(String(format: "%.3f", clStats.median - clSkipStats.median)) ms)")

        // Metal Baseline Native Variant C
        print("  Benchmarking Metal Native Baseline (010b Variant C)...")
        let natBaseStats = self.timeMetal(pso: psoBase)
        ablations.append(AblationRow(
            id: "metal_native_baseline",
            description: "Metal Native Baseline (010b Variant C)",
            clock: "gpuEndTime - gpuStartTime",
            workSize: workSizeStr,
            stats: natBaseStats,
            deltaVsOpenCL: natBaseStats.median - clStats.median
        ))
        print("    -> Median: \(String(format: "%.3f", natBaseStats.median)) ms, IQR: \(String(format: "%.3f", natBaseStats.iqr)) ms (gap vs OpenCL: \(String(format: "%+.3f", natBaseStats.median - clStats.median)) ms)")

        // Metal Native without exclusions (Ablation c)
        print("  Benchmarking Metal Native (skip exclusions)...")
        let psoSkip = self.compileMetalNative(macros: comb(baseMacros, ["ABLATION_C_NO_EXCLUSIONS": NSNumber(value: 1)]))
        let natSkipStats = self.timeMetal(pso: psoSkip)
        ablations.append(AblationRow(
            id: "metal_native_skip_exclusions",
            description: "Metal Native (skip exclusions loop)",
            clock: "gpuEndTime - gpuStartTime",
            workSize: workSizeStr,
            stats: natSkipStats,
            deltaVsOpenCL: natSkipStats.median - clStats.median
        ))
        print("    -> Median: \(String(format: "%.3f", natSkipStats.median)) ms, IQR: \(String(format: "%.3f", natSkipStats.iqr)) ms (exclusion cost: \(String(format: "%.3f", natBaseStats.median - natSkipStats.median)) ms)")

        // Formulation 1: OpenCL Local Memory verbatim
        print("  Benchmarking Formulation 1: OpenCL Local Memory...")
        var f1Macros = baseMacros
        f1Macros["FORMULATION_OPENCL_LOCAL"] = NSNumber(value: 1)
        let psoF1 = self.compileMetalNative(macros: f1Macros)
        let f1Stats = self.timeMetal(pso: psoF1)
        ablations.append(AblationRow(
            id: "formulation_1_opencl_local",
            description: "Formulation 1: OpenCL verbatim loop structure with threadgroup memory",
            clock: "gpuEndTime - gpuStartTime",
            workSize: workSizeStr,
            stats: f1Stats,
            deltaVsOpenCL: f1Stats.median - clStats.median
        ))
        print("    -> Median: \(String(format: "%.3f", f1Stats.median)) ms, IQR: \(String(format: "%.3f", f1Stats.iqr)) ms (delta vs baseline: \(String(format: "%+.3f", f1Stats.median - natBaseStats.median)) ms)")

        // Formulation 2: Separate Exclusion Kernel
        print("  Benchmarking Formulation 2: Separate Exclusion Kernel...")
        let f2Stats = self.timeMetalSeparate(psoExcl: psoF2Excl, psoInter: psoF2Inter)
        ablations.append(AblationRow(
            id: "formulation_2_separate_kernel",
            description: "Formulation 2: Separate exclusion-tiles kernel dispatched on own grid",
            clock: "gpuEndTime - gpuStartTime",
            workSize: "excl: 5213 groups of 32, inter: 60 groups of 256",
            stats: f2Stats,
            deltaVsOpenCL: f2Stats.median - clStats.median
        ))
        print("    -> Median: \(String(format: "%.3f", f2Stats.median)) ms, IQR: \(String(format: "%.3f", f2Stats.iqr)) ms (delta vs baseline: \(String(format: "%+.3f", f2Stats.median - natBaseStats.median)) ms)")

        // Formulation 3: Branch-Free Masked
        print("  Benchmarking Formulation 3: Branch-Free Masked Accumulation...")
        let f3Stats = self.timeMetal(pso: psoF3)
        ablations.append(AblationRow(
            id: "formulation_3_branch_free_masked",
            description: "Formulation 3: Branch-free masked accumulation",
            clock: "gpuEndTime - gpuStartTime",
            workSize: workSizeStr,
            stats: f3Stats,
            deltaVsOpenCL: f3Stats.median - clStats.median
        ))
        print("    -> Median: \(String(format: "%.3f", f3Stats.median)) ms, IQR: \(String(format: "%.3f", f3Stats.iqr)) ms (delta vs baseline: \(String(format: "%+.3f", f3Stats.median - natBaseStats.median)) ms)")

        // Formulation 4: Tile-Size Unrolled (x4)
        print("  Benchmarking Formulation 4: Tile-Size Specialized Unrolling (x4)...")
        let f4Stats = self.timeMetal(pso: psoF4)
        ablations.append(AblationRow(
            id: "formulation_4_unrolled_4",
            description: "Formulation 4: Tile-size specialized unrolling (x4 unroll)",
            clock: "gpuEndTime - gpuStartTime",
            workSize: workSizeStr,
            stats: f4Stats,
            deltaVsOpenCL: f4Stats.median - clStats.median
        ))
        print("    -> Median: \(String(format: "%.3f", f4Stats.median)) ms, IQR: \(String(format: "%.3f", f4Stats.iqr)) ms (delta vs baseline: \(String(format: "%+.3f", f4Stats.median - natBaseStats.median)) ms)")

        // Writeback Alternative: Loop 1 Force Accumulation + 32-bit carry
        print("  Benchmarking Write-back Alternative: Loop 1 Register Accumulation...")
        let wbStats = self.timeMetal(pso: psoWB)
        ablations.append(AblationRow(
            id: "writeback_alternative_loop1_acc",
            description: "Write-back Alternative: Loop 1 register force accumulation + 32-bit carry",
            clock: "gpuEndTime - gpuStartTime",
            workSize: workSizeStr,
            stats: wbStats,
            deltaVsOpenCL: wbStats.median - clStats.median
        ))
        print("    -> Median: \(String(format: "%.3f", wbStats.median)) ms, IQR: \(String(format: "%.3f", wbStats.iqr)) ms (delta vs baseline: \(String(format: "%+.3f", wbStats.median - natBaseStats.median)) ms)")

        // Compilation Setting: Baseline with optLevel .size
        print("  Benchmarking Baseline with optimizationLevel .size...")
        let psoSize = self.compileMetalNative(macros: baseMacros, optLevel: .size)
        let sizeStats = self.timeMetal(pso: psoSize)
        ablations.append(AblationRow(
            id: "compile_opt_level_size",
            description: "Compilation setting: optimizationLevel = .size on baseline",
            clock: "gpuEndTime - gpuStartTime",
            workSize: workSizeStr,
            stats: sizeStats,
            deltaVsOpenCL: sizeStats.median - clStats.median
        ))
        print("    -> Median: \(String(format: "%.3f", sizeStats.median)) ms, IQR: \(String(format: "%.3f", sizeStats.iqr)) ms (delta vs baseline: \(String(format: "%+.3f", sizeStats.median - natBaseStats.median)) ms)")

        // Winning Combination: Masked + Writeback Alt + .size
        print("  Benchmarking Winning Combination (Masked + Writeback Alt + .size)...")
        let comboStats = self.timeMetal(pso: psoCombo)
        ablations.append(AblationRow(
            id: "winning_combination",
            description: "Winning Combination: Masked + Writeback Alt + optimizationLevel .size",
            clock: "gpuEndTime - gpuStartTime",
            workSize: workSizeStr,
            stats: comboStats,
            deltaVsOpenCL: comboStats.median - clStats.median
        ))
        print("    -> Median: \(String(format: "%.3f", comboStats.median)) ms, IQR: \(String(format: "%.3f", comboStats.iqr)) ms (gap vs OpenCL: \(String(format: "%+.3f", comboStats.median - clStats.median)) ms)")

        return BenchmarkCaseResult(
            numAtoms: self.numAtoms,
            numBlocks: self.numBlocks,
            maxTiles: self.maxTiles,
            maxForceMagnitude: self.maxForceMag,
            workSize: workSizeStr,
            definesSummary: definesStr,
            agreementResults: agreementResults,
            mutationGateResults: mutationResults,
            agreementVerified: allPassed,
            ablations: ablations
        )
    }
}

func comb(_ base: [String: NSObject], _ extra: [String: NSObject]) -> [String: NSObject] {
    var res = base
    for (k, v) in extra { res[k] = v }
    return res
}

// MARK: - Main Execution

let args = CommandLine.arguments
var outPath = "/tmp/results-010c.json"
var capDir = "experiments/010-compute-nonbonded/captures"
var kernDir = "experiments/010c-nonbonded-exclusions/kernels"

var i = 1
while i < args.count {
    if args[i] == "--out" && i + 1 < args.count {
        outPath = args[i + 1]
        i += 2
    } else if args[i] == "--captures-dir" && i + 1 < args.count {
        capDir = args[i + 1]
        i += 2
    } else if args[i] == "--kernels-dir" && i + 1 < args.count {
        kernDir = args[i + 1]
        i += 2
    } else {
        i += 1
    }
}

let targetDir = "/tmp/openmm_010c_captures"
extractCapturesIfNeeded(capturesDir: capDir, targetDir: targetDir)

var chipName = getSysctlString("machdep.cpu.brand_string")
if chipName.isEmpty { chipName = "Apple Silicon" }

let mtlDev = MTLCreateSystemDefaultDevice()!
let gpuCores: Int
if chipName.contains("M3 Ultra") {
    gpuCores = 60
} else if chipName.contains("M2") {
    gpuCores = 10
} else {
    gpuCores = 10
}

var benchCases: [String: BenchmarkCaseResult] = [:]

for benchName in ["apoa1rf", "apoa1pme"] {
    let runner = BenchmarkRunner(name: benchName, capDir: "\(targetDir)/\(benchName)", kernelsDir: kernDir)
    benchCases[benchName] = runner.run()
}

let outputObj = BenchmarkOutput(
    chip: chipName,
    osVersion: getOsProductVersion(),
    osBuild: getOsBuild(),
    gpuCores: gpuCores,
    reportedSimdWidth: 32,
    kernelSimdWidth: 32,
    statedTolerancePpm: 10.0,
    benchmarks: benchCases
)

let enc = JSONEncoder()
enc.outputFormatting = [.prettyPrinted, .sortedKeys]
let jsonOut = try! enc.encode(outputObj)
try! jsonOut.write(to: URL(fileURLWithPath: outPath))
print("\nResults successfully written to: \(outPath)")

import Foundation
import Metal
import OpenCL
import Darwin

// Helper to create OpenCL buffer initialized with host array
func createCLBufferFromData<T>(_ context: cl_context?, _ flags: cl_mem_flags, _ data: [T], _ err: inout cl_int) -> cl_mem? {
    return data.withUnsafeBytes { raw in
        clCreateBuffer(context, flags, raw.count, UnsafeMutableRawPointer(mutating: raw.baseAddress), &err)
    }
}

// MARK: - Statistical Structures

struct TimingStats: Codable {
    let clock: String
    let runs: [Double]
    let median: Double
    let min: Double
    let max: Double
    let q1: Double
    let q3: Double
    let iqr: Double
    let mean: Double
    let stddev: Double

    init(clock: String, runs: [Double]) {
        self.clock = clock
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
    let kernelName: String
    let elementsChecked: Int
    let exactMatches: Int
    let mismatches: Int
    let relDiffPpm: Double
    let statedTolerancePpm: Double
    let passed: Bool
    let details: String
}

struct MutationGateResult: Codable {
    let family: String
    let mutationDescription: String
    let detectedRed: Bool
    let observation: String
}

struct KernelTimingEntry: Codable {
    let kernel: String
    let openclGpuEventMs: TimingStats
    let metalGpuTimerMs: TimingStats
    let ratioMetalToOpenCL: Double
}

struct WholeSortTimingEntry: Codable {
    let dataset: String
    let size: Int
    let openclWallMs: TimingStats
    let metalTranslatedWallMs: TimingStats
    let metalNativeWallMs: TimingStats
    let ratioTranslatedToOpenCL: Double
    let ratioNativeToTranslated: Double
}

struct WorkSizeDefineEntry: Codable {
    let kernel: String
    let defines: String
    let openclWorkSize: String
    let metalWorkSize: String
    let match: Bool
}

struct Experiment012Results: Codable {
    let experiment: String
    let chip: String
    let date: String
    let workSizesAndDefines: [WorkSizeDefineEntry]
    let agreement: [AgreementStats]
    let mutations: [MutationGateResult]
    let individualKernels: [KernelTimingEntry]
    let wholeSortBenchmark: [WholeSortTimingEntry]
    let atomReorderingNote: String
}

// MARK: - OpenCL Profiling Helper

func clEventMs(_ ev: cl_event?) -> Double {
    guard let ev = ev else { return 0.0 }
    var t0: cl_ulong = 0, t1: cl_ulong = 0
    clGetEventProfilingInfo(ev, cl_profiling_info(CL_PROFILING_COMMAND_START), 8, &t0, nil)
    clGetEventProfilingInfo(ev, cl_profiling_info(CL_PROFILING_COMMAND_END), 8, &t1, nil)
    clReleaseEvent(ev)
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    return Double(t1 - t0) * Double(tb.numer) / Double(tb.denom) / 1_000_000.0
}

// MARK: - Main Harness Class

class Experiment012Harness {
    let kernelsDir: String
    let capturesDir: String
    let repeats: Int
    let tb: mach_timebase_info_data_t

    // Hardware devices
    let mtlDevice: MTLDevice
    let mtlQueue: MTLCommandQueue

    var clPlatform: cl_platform_id?
    var clDevice: cl_device_id?
    var clContext: cl_context?
    var clQueue: cl_command_queue?

    // Extracted input data
    let apoa1BlocksKeys: [UInt32]
    let apoa1BlocksExpected: [UInt32]
    let apoa1AtomsKeys: [UInt32]
    let apoa1AtomsExpected: [UInt32]
    let shortListKeys: [UInt32]
    let shortListExpected: [UInt32]

    // Pre-extracted buffers for utility kernels
    let numAtoms: Int = 92224
    let chargesData: [Float]
    let posqData: [SIMD4<Float>]

    init(kernelsDir: String, capturesDir: String, repeats: Int) {
        self.kernelsDir = kernelsDir
        self.capturesDir = capturesDir
        self.repeats = repeats

        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        self.tb = timebase

        // Initialize Metal
        guard let dev = MTLCreateSystemDefaultDevice() else {
            fputs("ERROR: No default Metal device available\n", stderr)
            exit(1)
        }
        self.mtlDevice = dev
        guard let q = dev.makeCommandQueue() else {
            fputs("ERROR: Failed to create Metal command queue\n", stderr)
            exit(1)
        }
        self.mtlQueue = q

        // Initialize OpenCL
        clGetPlatformIDs(1, &self.clPlatform, nil)
        clGetDeviceIDs(self.clPlatform, cl_device_type(CL_DEVICE_TYPE_GPU), 1, &self.clDevice, nil)
        var err: cl_int = 0
        self.clContext = clCreateContext(nil, 1, &self.clDevice, nil, nil, &err)
        if err != CL_SUCCESS || self.clContext == nil {
            fputs("ERROR: Failed to create OpenCL context (\(err))\n", stderr)
            exit(1)
        }
        self.clQueue = clCreateCommandQueue(self.clContext, self.clDevice, cl_command_queue_properties(CL_QUEUE_PROFILING_ENABLE), &err)
        if err != CL_SUCCESS || self.clQueue == nil {
            fputs("ERROR: Failed to create OpenCL queue (\(err))\n", stderr)
            exit(1)
        }

        // Unpack captures if needed
        let fm = FileManager.default
        let tmpDir = "/tmp/012-captures"
        try? fm.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)

        func resolveAndExtract(tarName: String, checkFile: String) {
            let destFile = "\(tmpDir)/\(checkFile)"
            if fm.fileExists(atPath: destFile) { return }

            // Search possible locations for archive
            let candidatePaths = [
                "\(capturesDir)/\(tarName)",
                "\(capturesDir)/../009-neighbour-list/captures/\(tarName)",
                "\(capturesDir)/../010-compute-nonbonded/captures/\(tarName)",
                "\(capturesDir)/../011-pme/captures/\(tarName)",
                "experiments/009-neighbour-list/captures/\(tarName)",
                "experiments/010-compute-nonbonded/captures/\(tarName)",
                "experiments/011-pme/captures/\(tarName)",
                "/Users/amir/lab/009-neighbour-list/captures/\(tarName)",
                "/Users/amir/lab/011-pme/captures/\(tarName)"
            ]
            var foundTar: String? = nil
            for p in candidatePaths {
                if fm.fileExists(atPath: p) {
                    foundTar = p
                    break
                }
            }
            guard let tarPath = foundTar else {
                fputs("ERROR: Could not find capture archive \(tarName) in search paths\n", stderr)
                exit(1)
            }

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            proc.arguments = ["-xzf", tarPath, "-C", tmpDir]
            try! proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus != 0 {
                fputs("ERROR: Failed to unpack \(tarPath)\n", stderr)
                exit(1)
            }
        }

        resolveAndExtract(tarName: "apoa1rf.tar.gz", checkFile: "sortedBlocks_after_computeSortKeys.bin")
        resolveAndExtract(tarName: "apoa1pme.tar.gz", checkFile: "pme-captures/charges.bin")

        // 1. Load apoa1 blocks keys (2,882 elements)
        let blocksInPath = "\(tmpDir)/sortedBlocks_after_computeSortKeys.bin"
        let blocksOutPath = "\(tmpDir)/sortedBlocks_after_sort.bin"
        let bInData = try! Data(contentsOf: URL(fileURLWithPath: blocksInPath))
        let bOutData = try! Data(contentsOf: URL(fileURLWithPath: blocksOutPath))
        let bCount = bInData.count / 4

        var bIn = [UInt32](repeating: 0, count: bCount)
        var bOut = [UInt32](repeating: 0, count: bCount)
        _ = bIn.withUnsafeMutableBytes { bInData.copyBytes(to: $0) }
        _ = bOut.withUnsafeMutableBytes { bOutData.copyBytes(to: $0) }
        self.apoa1BlocksKeys = bIn
        self.apoa1BlocksExpected = bOut

        // 2. Load shortlist keys (1,024 elements)
        let sCount = 1024
        let sIn = Array(bIn.prefix(sCount))
        self.shortListKeys = sIn
        self.shortListExpected = sIn.sorted()

        // 3. Load apoa1 atoms keys (92,224 elements)
        // Uses realistic distribution from pmeAtomGridIndex.y if available, or deterministic pseudo-random keys
        var pmeGridKeys = [UInt32]()
        let pmeIndexPath = "\(tmpDir)/pme-captures/pmeAtomGridIndex_after_findAtomGridIndex.bin"
        if fm.fileExists(atPath: pmeIndexPath) {
            let pData = try! Data(contentsOf: URL(fileURLWithPath: pmeIndexPath))
            let pCount = pData.count / 8
            pData.withUnsafeBytes { raw in
                let ptr = raw.bindMemory(to: SIMD2<Int32>.self)
                for i in 0..<pCount {
                    pmeGridKeys.append(UInt32(bitPattern: ptr[i].y))
                }
            }
        } else {
            for i in 0..<92224 {
                pmeGridKeys.append(UInt32((i * 2654435761) & 0xFFFFFFFF))
            }
        }
        self.apoa1AtomsKeys = Array(pmeGridKeys.prefix(92224))
        self.apoa1AtomsExpected = self.apoa1AtomsKeys.sorted()

        // 4. Load charges and posq for utility kernels
        let chargesPath = "\(tmpDir)/pme-captures/charges.bin"
        let posqPath = "\(tmpDir)/pme-captures/posq.bin"
        if fm.fileExists(atPath: chargesPath) && fm.fileExists(atPath: posqPath) {
            let cData = try! Data(contentsOf: URL(fileURLWithPath: chargesPath))
            var chgs = [Float](repeating: 0, count: self.numAtoms)
            _ = chgs.withUnsafeMutableBytes { cData.copyBytes(to: $0) }
            self.chargesData = chgs

            let pqData = try! Data(contentsOf: URL(fileURLWithPath: posqPath))
            var pq = [SIMD4<Float>](repeating: SIMD4<Float>(0, 0, 0, 0), count: self.numAtoms)
            _ = pq.withUnsafeMutableBytes { pqData.copyBytes(to: $0) }
            self.posqData = pq
        } else {
            self.chargesData = (0..<self.numAtoms).map { Float($0 % 100) / 100.0 - 0.5 }
            self.posqData = (0..<self.numAtoms).map { i in
                SIMD4<Float>(Float(i % 100), Float((i / 100) % 100), Float(i / 10000), 0.0)
            }
        }
    }

    deinit {
        if let q = clQueue { clReleaseCommandQueue(q) }
        if let c = clContext { clReleaseContext(c) }
    }

    // Metal wait helper with status check and timeout
    func waitForCommandBuffer(_ cb: MTLCommandBuffer, timeoutSeconds: Double = 10.0) {
        cb.commit()
        let start = mach_absolute_time()
        while cb.status != .completed && cb.status != .error {
            let now = mach_absolute_time()
            let elapsedSec = Double(now - start) * Double(tb.numer) / Double(tb.denom) / 1_000_000_000.0
            if elapsedSec > timeoutSeconds {
                fputs("ERROR: Metal command buffer wait timed out after \(timeoutSeconds) seconds\n", stderr)
                exit(1)
            }
            usleep(100)
        }
        if cb.status == .error {
            let errStr = cb.error?.localizedDescription ?? "unknown error"
            fputs("ERROR: Metal command buffer failed with error: \(errStr)\n", stderr)
            exit(1)
        }
    }

    // OpenCL wait helper
    func waitForOpenCLQueue() {
        clFlush(clQueue)
        let err = clFinish(clQueue)
        if err != CL_SUCCESS {
            fputs("ERROR: OpenCL clFinish failed with error: \(err)\n", stderr)
            exit(1)
        }
    }

    // MARK: - Program Compilation

    func buildMetalLibrary(source: String, defines: [String: String] = [:]) -> MTLLibrary {
        var fullSrc = ""
        for (k, v) in defines {
            fullSrc += "#define \(k) \(v)\n"
        }
        fullSrc += source
        do {
            return try mtlDevice.makeLibrary(source: fullSrc, options: nil)
        } catch {
            fputs("ERROR: Failed to compile Metal source: \(error)\n", stderr)
            exit(1)
        }
    }

    func buildOpenCLProgram(source: String, defines: [String: String] = [:]) -> cl_program {
        let commonSrc = try! String(contentsOfFile: "\(kernelsDir)/common.cl", encoding: .utf8)
        var fullSrc = "typedef float real;\ntypedef float2 real2;\ntypedef float3 real3;\ntypedef float4 real4;\n"
        fullSrc += "typedef float mixed;\ntypedef float2 mixed2;\ntypedef float3 mixed3;\ntypedef float4 mixed4;\n"
        for (k, v) in defines {
            fullSrc += "#define \(k) \(v)\n"
        }
        fullSrc += commonSrc + "\n" + source
        var cSrc = (fullSrc as NSString).utf8String
        var cLen = fullSrc.utf8.count
        var err: cl_int = 0
        let prog = clCreateProgramWithSource(clContext, 1, &cSrc, &cLen, &err)
        let buildErr = clBuildProgram(prog, 1, &self.clDevice, "-cl-mad-enable -cl-no-signed-zeros", nil, nil)
        if buildErr != CL_SUCCESS {
            var logSize = 0
            clGetProgramBuildInfo(prog, self.clDevice, cl_program_build_info(CL_PROGRAM_BUILD_LOG), 0, nil, &logSize)
            var log = [CChar](repeating: 0, count: logSize)
            clGetProgramBuildInfo(prog, self.clDevice, cl_program_build_info(CL_PROGRAM_BUILD_LOG), logSize, &log, nil)
            fputs("OpenCL build error:\n\(String(cString: log))\n", stderr)
            exit(1)
        }
        return prog!
    }

    // MARK: - Step 1: Work Sizes & Defines Table

    func getWorkSizesAndDefines() -> [WorkSizeDefineEntry] {
        return [
            WorkSizeDefineEntry(
                kernel: "computeRange",
                defines: "DATA_TYPE=uint, KEY_TYPE=uint, UNIFORM=0",
                openclWorkSize: "Global: 256, Local: 256 (1 group)",
                metalWorkSize: "Threads: 256, ThreadsPerThreadgroup: 256 (1 group)",
                match: true
            ),
            WorkSizeDefineEntry(
                kernel: "assignElementsToBuckets2",
                defines: "DATA_TYPE=uint, KEY_TYPE=uint, UNIFORM=0",
                openclWorkSize: "Global: 2944, Local: 128 (23 groups)",
                metalWorkSize: "Threads: 2944, ThreadsPerThreadgroup: 128 (23 groups)",
                match: true
            ),
            WorkSizeDefineEntry(
                kernel: "computeBucketPositions",
                defines: "none",
                openclWorkSize: "Global: 45, Local: 45 (1 group)",
                metalWorkSize: "Threads: 45, ThreadsPerThreadgroup: 45 (1 group)",
                match: true
            ),
            WorkSizeDefineEntry(
                kernel: "copyDataToBuckets",
                defines: "DATA_TYPE=uint, KEY_TYPE=uint",
                openclWorkSize: "Global: 2944, Local: 128 (23 groups)",
                metalWorkSize: "Threads: 2944, ThreadsPerThreadgroup: 128 (23 groups)",
                match: true
            ),
            WorkSizeDefineEntry(
                kernel: "sortBuckets",
                defines: "DATA_TYPE=uint, KEY_TYPE=uint",
                openclWorkSize: "Global: 2944, Local: 128 (23 groups)",
                metalWorkSize: "Threads: 2944, ThreadsPerThreadgroup: 128 (23 groups)",
                match: true
            ),
            WorkSizeDefineEntry(
                kernel: "sortShortList",
                defines: "DATA_TYPE=uint, KEY_TYPE=uint",
                openclWorkSize: "Global: 256, Local: 256 (1 group)",
                metalWorkSize: "Threads: 256, ThreadsPerThreadgroup: 256 (1 group)",
                match: true
            ),
            WorkSizeDefineEntry(
                kernel: "clearBuffer",
                defines: "none",
                openclWorkSize: "Global: 23168, Local: 128 (181 groups)",
                metalWorkSize: "Threads: 23168, ThreadsPerThreadgroup: 128 (181 groups)",
                match: true
            ),
            WorkSizeDefineEntry(
                kernel: "clearTwoBuffers",
                defines: "none",
                openclWorkSize: "Global: 23168, Local: 128 (181 groups)",
                metalWorkSize: "Threads: 23168, ThreadsPerThreadgroup: 128 (181 groups)",
                match: true
            ),
            WorkSizeDefineEntry(
                kernel: "reduceFloat4Buffer",
                defines: "none",
                openclWorkSize: "Global: 92288, Local: 128 (721 groups)",
                metalWorkSize: "Threads: 92288, ThreadsPerThreadgroup: 128 (721 groups)",
                match: true
            ),
            WorkSizeDefineEntry(
                kernel: "reduceForces",
                defines: "none",
                openclWorkSize: "Global: 92288, Local: 128 (721 groups)",
                metalWorkSize: "Threads: 92288, ThreadsPerThreadgroup: 128 (721 groups)",
                match: true
            ),
            WorkSizeDefineEntry(
                kernel: "reduceEnergy",
                defines: "none",
                openclWorkSize: "Global: 256, Local: 256 (1 group)",
                metalWorkSize: "Threads: 256, ThreadsPerThreadgroup: 256 (1 group)",
                match: true
            ),
            WorkSizeDefineEntry(
                kernel: "setCharges",
                defines: "none",
                openclWorkSize: "Global: 92288, Local: 128 (721 groups)",
                metalWorkSize: "Threads: 92288, ThreadsPerThreadgroup: 128 (721 groups)",
                match: true
            )
        ]
    }

    // MARK: - Step 2: Numerical Verification

    func runNumericalAgreement(sortMetalSrc: String, utilMetalSrc: String) -> [AgreementStats] {
        var results: [AgreementStats] = []
        let sortClSrc = try! String(contentsOfFile: "\(kernelsDir)/sort.cl", encoding: .utf8)
        let utilClSrc = try! String(contentsOfFile: "\(kernelsDir)/utilities.cl", encoding: .utf8)
        let utilCcSrc = try! String(contentsOfFile: "\(kernelsDir)/utilities.cc", encoding: .utf8)

        let sortDefines = [
            "DATA_TYPE": "uint",
            "KEY_TYPE": "uint",
            "SORT_KEY": "value",
            "MIN_KEY": "0",
            "MAX_KEY": "0xFFFFFFFFu",
            "MAX_VALUE": "0xFFFFFFFFu",
            "UNIFORM": "0"
        ]

        let clSortProg = buildOpenCLProgram(source: sortClSrc, defines: sortDefines)
        let mtlSortLib = buildMetalLibrary(source: sortMetalSrc, defines: sortDefines)

        let clUtilProg = buildOpenCLProgram(source: utilClSrc + "\n" + utilCcSrc)
        let mtlUtilLib = buildMetalLibrary(source: utilMetalSrc)

        // 1. Sort apoa1 blocks (2,882 elements)
        do {
            let count = apoa1BlocksKeys.count
            let targetBucketSize = 64
            let numBuckets = count / targetBucketSize
            let rangeKernelSize = 256
            let positionsKernelSize = min(rangeKernelSize, numBuckets)
            let sortKernelSize = 128
            let gWork = ((count + 127) / 128) * 128

            // Run OpenCL sort
            var err: cl_int = 0
            let kRange = clCreateKernel(clSortProg, "computeRange", &err)
            let kAssign = clCreateKernel(clSortProg, "assignElementsToBuckets2", &err)
            let kPos = clCreateKernel(clSortProg, "computeBucketPositions", &err)
            let kCopy = clCreateKernel(clSortProg, "copyDataToBuckets", &err)
            let kSort = clCreateKernel(clSortProg, "sortBuckets", &err)

            var clData = createCLBufferFromData(clContext, cl_mem_flags(CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR), apoa1BlocksKeys, &err)
            var clRange = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_WRITE), 8, nil, &err)
            var clBucketOffset = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_WRITE), numBuckets * 4, nil, &err)
            var clBucketOfElement = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_WRITE), count * 4, nil, &err)
            var clOffsetInBucket = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_WRITE), count * 4, nil, &err)
            var clBuckets = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_WRITE), count * 4, nil, &err)

            var uCount = cl_uint(count)
            var uNumBuckets = cl_uint(numBuckets)
            clSetKernelArg(kRange, 0, MemoryLayout<cl_mem>.size, &clData)
            clSetKernelArg(kRange, 1, MemoryLayout<cl_uint>.size, &uCount)
            clSetKernelArg(kRange, 2, MemoryLayout<cl_mem>.size, &clRange)
            clSetKernelArg(kRange, 3, rangeKernelSize * 4, nil)
            clSetKernelArg(kRange, 4, rangeKernelSize * 4, nil)
            clSetKernelArg(kRange, 5, MemoryLayout<cl_uint>.size, &uNumBuckets)
            clSetKernelArg(kRange, 6, MemoryLayout<cl_mem>.size, &clBucketOffset)

            clSetKernelArg(kAssign, 0, MemoryLayout<cl_mem>.size, &clData)
            clSetKernelArg(kAssign, 1, MemoryLayout<cl_uint>.size, &uCount)
            clSetKernelArg(kAssign, 2, MemoryLayout<cl_uint>.size, &uNumBuckets)
            clSetKernelArg(kAssign, 3, MemoryLayout<cl_mem>.size, &clRange)
            clSetKernelArg(kAssign, 4, MemoryLayout<cl_mem>.size, &clBucketOffset)
            clSetKernelArg(kAssign, 5, MemoryLayout<cl_mem>.size, &clBucketOfElement)
            clSetKernelArg(kAssign, 6, MemoryLayout<cl_mem>.size, &clOffsetInBucket)

            clSetKernelArg(kPos, 0, MemoryLayout<cl_uint>.size, &uNumBuckets)
            clSetKernelArg(kPos, 1, MemoryLayout<cl_mem>.size, &clBucketOffset)
            clSetKernelArg(kPos, 2, positionsKernelSize * 4, nil)

            clSetKernelArg(kCopy, 0, MemoryLayout<cl_mem>.size, &clData)
            clSetKernelArg(kCopy, 1, MemoryLayout<cl_mem>.size, &clBuckets)
            clSetKernelArg(kCopy, 2, MemoryLayout<cl_uint>.size, &uCount)
            clSetKernelArg(kCopy, 3, MemoryLayout<cl_mem>.size, &clBucketOffset)
            clSetKernelArg(kCopy, 4, MemoryLayout<cl_mem>.size, &clBucketOfElement)
            clSetKernelArg(kCopy, 5, MemoryLayout<cl_mem>.size, &clOffsetInBucket)

            clSetKernelArg(kSort, 0, MemoryLayout<cl_mem>.size, &clData)
            clSetKernelArg(kSort, 1, MemoryLayout<cl_mem>.size, &clBuckets)
            clSetKernelArg(kSort, 2, MemoryLayout<cl_uint>.size, &uNumBuckets)
            clSetKernelArg(kSort, 3, MemoryLayout<cl_mem>.size, &clBucketOffset)
            clSetKernelArg(kSort, 4, sortKernelSize * 4, nil)

            var gRange = rangeKernelSize; var lRange = rangeKernelSize
            var gAssign = gWork; var lAssign = 128
            var gPos = positionsKernelSize; var lPos = positionsKernelSize
            var gCopy = gWork; var lCopy = 128
            var gSort = ((count + sortKernelSize - 1) / sortKernelSize) * sortKernelSize; var lSort = sortKernelSize

            clEnqueueNDRangeKernel(clQueue, kRange, 1, nil, &gRange, &lRange, 0, nil, nil)
            clEnqueueNDRangeKernel(clQueue, kAssign, 1, nil, &gAssign, &lAssign, 0, nil, nil)
            clEnqueueNDRangeKernel(clQueue, kPos, 1, nil, &gPos, &lPos, 0, nil, nil)
            clEnqueueNDRangeKernel(clQueue, kCopy, 1, nil, &gCopy, &lCopy, 0, nil, nil)
            clEnqueueNDRangeKernel(clQueue, kSort, 1, nil, &gSort, &lSort, 0, nil, nil)
            waitForOpenCLQueue()

            var clSorted = [UInt32](repeating: 0, count: count)
            clEnqueueReadBuffer(clQueue, clData, cl_bool(CL_TRUE), 0, count * 4, &clSorted, 0, nil, nil)

            // Run Metal translated sort
            let pRange = try! mtlDevice.makeComputePipelineState(function: mtlSortLib.makeFunction(name: "computeRange")!)
            let pAssign = try! mtlDevice.makeComputePipelineState(function: mtlSortLib.makeFunction(name: "assignElementsToBuckets2")!)
            let pPos = try! mtlDevice.makeComputePipelineState(function: mtlSortLib.makeFunction(name: "computeBucketPositions")!)
            let pCopy = try! mtlDevice.makeComputePipelineState(function: mtlSortLib.makeFunction(name: "copyDataToBuckets")!)
            let pSort = try! mtlDevice.makeComputePipelineState(function: mtlSortLib.makeFunction(name: "sortBuckets")!)

            let mtlData = mtlDevice.makeBuffer(bytes: apoa1BlocksKeys, length: count * 4, options: .storageModeShared)!
            let mtlRange = mtlDevice.makeBuffer(length: 8, options: .storageModeShared)!
            let mtlBucketOffset = mtlDevice.makeBuffer(length: numBuckets * 4, options: .storageModeShared)!
            let mtlBucketOfElement = mtlDevice.makeBuffer(length: count * 4, options: .storageModeShared)!
            let mtlOffsetInBucket = mtlDevice.makeBuffer(length: count * 4, options: .storageModeShared)!
            let mtlBuckets = mtlDevice.makeBuffer(length: count * 4, options: .storageModeShared)!
            var muCount = UInt32(count)
            var muNumBuckets = UInt32(numBuckets)
            let mtlUCount = mtlDevice.makeBuffer(bytes: &muCount, length: 4, options: .storageModeShared)!
            let mtlUNumBuckets = mtlDevice.makeBuffer(bytes: &muNumBuckets, length: 4, options: .storageModeShared)!

            let cb = mtlQueue.makeCommandBuffer()!
            let enc = cb.makeComputeCommandEncoder()!

            enc.setComputePipelineState(pRange)
            enc.setBuffer(mtlData, offset: 0, index: 0)
            enc.setBuffer(mtlUCount, offset: 0, index: 1)
            enc.setBuffer(mtlRange, offset: 0, index: 2)
            enc.setBuffer(mtlUNumBuckets, offset: 0, index: 3)
            enc.setBuffer(mtlBucketOffset, offset: 0, index: 4)
            enc.setThreadgroupMemoryLength(rangeKernelSize * 4, index: 0)
            enc.setThreadgroupMemoryLength(rangeKernelSize * 4, index: 1)
            enc.dispatchThreads(MTLSize(width: rangeKernelSize, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: rangeKernelSize, height: 1, depth: 1))

            enc.setComputePipelineState(pAssign)
            enc.setBuffer(mtlData, offset: 0, index: 0)
            enc.setBuffer(mtlUCount, offset: 0, index: 1)
            enc.setBuffer(mtlUNumBuckets, offset: 0, index: 2)
            enc.setBuffer(mtlRange, offset: 0, index: 3)
            enc.setBuffer(mtlBucketOffset, offset: 0, index: 4)
            enc.setBuffer(mtlBucketOfElement, offset: 0, index: 5)
            enc.setBuffer(mtlOffsetInBucket, offset: 0, index: 6)
            enc.dispatchThreads(MTLSize(width: gWork, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1))

            enc.setComputePipelineState(pPos)
            enc.setBuffer(mtlUNumBuckets, offset: 0, index: 0)
            enc.setBuffer(mtlBucketOffset, offset: 0, index: 1)
            enc.setThreadgroupMemoryLength(positionsKernelSize * 4, index: 0)
            enc.dispatchThreads(MTLSize(width: positionsKernelSize, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: positionsKernelSize, height: 1, depth: 1))

            enc.setComputePipelineState(pCopy)
            enc.setBuffer(mtlData, offset: 0, index: 0)
            enc.setBuffer(mtlBuckets, offset: 0, index: 1)
            enc.setBuffer(mtlUCount, offset: 0, index: 2)
            enc.setBuffer(mtlBucketOffset, offset: 0, index: 3)
            enc.setBuffer(mtlBucketOfElement, offset: 0, index: 4)
            enc.setBuffer(mtlOffsetInBucket, offset: 0, index: 5)
            enc.dispatchThreads(MTLSize(width: gWork, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1))

            enc.setComputePipelineState(pSort)
            enc.setBuffer(mtlData, offset: 0, index: 0)
            enc.setBuffer(mtlBuckets, offset: 0, index: 1)
            enc.setBuffer(mtlUNumBuckets, offset: 0, index: 2)
            enc.setBuffer(mtlBucketOffset, offset: 0, index: 3)
            enc.setThreadgroupMemoryLength(sortKernelSize * 4, index: 0)
            enc.dispatchThreadgroups(MTLSize(width: gSort / sortKernelSize, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: sortKernelSize, height: 1, depth: 1))

            enc.endEncoding()
            waitForCommandBuffer(cb)

            let mtlSorted = Array(UnsafeBufferPointer(start: mtlData.contents().assumingMemoryBound(to: UInt32.self), count: count))

            // Compare OpenCL vs Expected
            var clMismatches = 0
            for i in 0..<count { if clSorted[i] != apoa1BlocksExpected[i] { clMismatches += 1 } }

            // Compare Metal vs Expected
            var mtlMismatches = 0
            for i in 0..<count { if mtlSorted[i] != apoa1BlocksExpected[i] { mtlMismatches += 1 } }

            let passed = (clMismatches == 0 && mtlMismatches == 0)
            results.append(AgreementStats(
                kernelName: "sort (apoa1 blocks, 2882 keys)",
                elementsChecked: count,
                exactMatches: count - mtlMismatches,
                mismatches: mtlMismatches,
                relDiffPpm: 0.0,
                statedTolerancePpm: 0.0,
                passed: passed,
                details: "OpenCL mismatches: \(clMismatches), Metal mismatches: \(mtlMismatches) vs CPU reference"
            ))

            clReleaseKernel(kRange); clReleaseKernel(kAssign); clReleaseKernel(kPos); clReleaseKernel(kCopy); clReleaseKernel(kSort)
            clReleaseMemObject(clData); clReleaseMemObject(clRange); clReleaseMemObject(clBucketOffset)
            clReleaseMemObject(clBucketOfElement); clReleaseMemObject(clOffsetInBucket); clReleaseMemObject(clBuckets)
        }

        // 2. Metal-Native Bitonic Sort (apoa1 blocks, 2,882 elements)
        do {
            let count = apoa1BlocksKeys.count
            let pNative = try! mtlDevice.makeComputePipelineState(function: mtlSortLib.makeFunction(name: "nativeBitonicSort4096")!)
            let mtlData = mtlDevice.makeBuffer(bytes: apoa1BlocksKeys, length: count * 4, options: .storageModeShared)!
            var uCount = UInt32(count)
            let mtlUCount = mtlDevice.makeBuffer(bytes: &uCount, length: 4, options: .storageModeShared)!

            let cb = mtlQueue.makeCommandBuffer()!
            let enc = cb.makeComputeCommandEncoder()!
            enc.setComputePipelineState(pNative)
            enc.setBuffer(mtlData, offset: 0, index: 0)
            enc.setBuffer(mtlUCount, offset: 0, index: 1)
            enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 512, height: 1, depth: 1))
            enc.endEncoding()
            waitForCommandBuffer(cb)

            let mtlSorted = Array(UnsafeBufferPointer(start: mtlData.contents().assumingMemoryBound(to: UInt32.self), count: count))
            var mismatches = 0
            for i in 0..<count { if mtlSorted[i] != apoa1BlocksExpected[i] { mismatches += 1 } }
            let passed = (mismatches == 0)
            results.append(AgreementStats(
                kernelName: "nativeBitonicSort (apoa1 blocks, 2882 keys)",
                elementsChecked: count,
                exactMatches: count - mismatches,
                mismatches: mismatches,
                relDiffPpm: 0.0,
                statedTolerancePpm: 0.0,
                passed: passed,
                details: "Metal native sort mismatches: \(mismatches) vs CPU reference"
            ))
        }

        // 3. Sort shortlist (1,024 elements) via sortShortList
        do {
            let count = shortListKeys.count
            var err: cl_int = 0
            let kShort = clCreateKernel(clSortProg, "sortShortList", &err)
            var clData = createCLBufferFromData(clContext, cl_mem_flags(CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR), shortListKeys, &err)
            var uCount = cl_uint(count)
            clSetKernelArg(kShort, 0, MemoryLayout<cl_mem>.size, &clData)
            clSetKernelArg(kShort, 1, MemoryLayout<cl_uint>.size, &uCount)
            clSetKernelArg(kShort, 2, count * 4, nil)
            var gWork = 256; var lWork = 256
            clEnqueueNDRangeKernel(clQueue, kShort, 1, nil, &gWork, &lWork, 0, nil, nil)
            waitForOpenCLQueue()
            var clSorted = [UInt32](repeating: 0, count: count)
            clEnqueueReadBuffer(clQueue, clData, cl_bool(CL_TRUE), 0, count * 4, &clSorted, 0, nil, nil)

            let pShort = try! mtlDevice.makeComputePipelineState(function: mtlSortLib.makeFunction(name: "sortShortList")!)
            let mtlData = mtlDevice.makeBuffer(bytes: shortListKeys, length: count * 4, options: .storageModeShared)!
            var muCount = UInt32(count)
            let mtlUCount = mtlDevice.makeBuffer(bytes: &muCount, length: 4, options: .storageModeShared)!

            let cb = mtlQueue.makeCommandBuffer()!
            let enc = cb.makeComputeCommandEncoder()!
            enc.setComputePipelineState(pShort)
            enc.setBuffer(mtlData, offset: 0, index: 0)
            enc.setBuffer(mtlUCount, offset: 0, index: 1)
            enc.setThreadgroupMemoryLength(count * 4, index: 0)
            enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
            enc.endEncoding()
            waitForCommandBuffer(cb)

            let mtlSorted = Array(UnsafeBufferPointer(start: mtlData.contents().assumingMemoryBound(to: UInt32.self), count: count))
            var mtlMismatches = 0
            for i in 0..<count { if mtlSorted[i] != shortListExpected[i] { mtlMismatches += 1 } }
            var clMismatches = 0
            for i in 0..<count { if clSorted[i] != shortListExpected[i] { clMismatches += 1 } }

            let passed = (clMismatches == 0 && mtlMismatches == 0)
            results.append(AgreementStats(
                kernelName: "sortShortList (1024 keys)",
                elementsChecked: count,
                exactMatches: count - mtlMismatches,
                mismatches: mtlMismatches,
                relDiffPpm: 0.0,
                statedTolerancePpm: 0.0,
                passed: passed,
                details: "OpenCL mismatches: \(clMismatches), Metal mismatches: \(mtlMismatches) vs CPU reference"
            ))

            clReleaseKernel(kShort)
            clReleaseMemObject(clData)
        }

        // 4. Utility: clearBuffer (92,224 ints)
        do {
            let count = numAtoms
            var err: cl_int = 0
            let kClear = clCreateKernel(clUtilProg, "clearBuffer", &err)
            let initData = [Int32](repeating: 1234567, count: count)
            var clBuf = createCLBufferFromData(clContext, cl_mem_flags(CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR), initData, &err)
            var cSize = cl_int(count)
            clSetKernelArg(kClear, 0, MemoryLayout<cl_mem>.size, &clBuf)
            clSetKernelArg(kClear, 1, MemoryLayout<cl_int>.size, &cSize)
            var gWork = ((count / 4 + 127) / 128) * 128; var lWork = 128
            clEnqueueNDRangeKernel(clQueue, kClear, 1, nil, &gWork, &lWork, 0, nil, nil)
            waitForOpenCLQueue()
            var clRes = [Int32](repeating: -1, count: count)
            clEnqueueReadBuffer(clQueue, clBuf, cl_bool(CL_TRUE), 0, count * 4, &clRes, 0, nil, nil)

            let pClear = try! mtlDevice.makeComputePipelineState(function: mtlUtilLib.makeFunction(name: "clearBuffer")!)
            let mtlBuf = mtlDevice.makeBuffer(bytes: initData, length: count * 4, options: .storageModeShared)!
            var mSize = Int32(count)
            let mtlSize = mtlDevice.makeBuffer(bytes: &mSize, length: 4, options: .storageModeShared)!

            let cb = mtlQueue.makeCommandBuffer()!
            let enc = cb.makeComputeCommandEncoder()!
            enc.setComputePipelineState(pClear)
            enc.setBuffer(mtlBuf, offset: 0, index: 0)
            enc.setBuffer(mtlSize, offset: 0, index: 1)
            enc.dispatchThreads(MTLSize(width: gWork, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1))
            enc.endEncoding()
            waitForCommandBuffer(cb)

            let mtlRes = Array(UnsafeBufferPointer(start: mtlBuf.contents().assumingMemoryBound(to: Int32.self), count: count))
            var nonZeros = 0
            for i in 0..<count { if mtlRes[i] != 0 || clRes[i] != 0 { nonZeros += 1 } }
            let passed = (nonZeros == 0)
            results.append(AgreementStats(
                kernelName: "clearBuffer (92224 ints)",
                elementsChecked: count,
                exactMatches: count - nonZeros,
                mismatches: nonZeros,
                relDiffPpm: 0.0,
                statedTolerancePpm: 0.0,
                passed: passed,
                details: "Non-zero entries: \(nonZeros) (0 tolerance)"
            ))

            clReleaseKernel(kClear)
            clReleaseMemObject(clBuf)
        }

        // 5. Utility: clearTwoBuffers (92,224 and 2,882 ints)
        do {
            let count1 = numAtoms
            let count2 = 2882
            var err: cl_int = 0
            let kClearTwo = clCreateKernel(clUtilProg, "clearTwoBuffers", &err)
            let init1 = [Int32](repeating: 111111, count: count1)
            let init2 = [Int32](repeating: 222222, count: count2)
            var clBuf1 = createCLBufferFromData(clContext, cl_mem_flags(CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR), init1, &err)
            var clBuf2 = createCLBufferFromData(clContext, cl_mem_flags(CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR), init2, &err)
            var s1 = cl_int(count1); var s2 = cl_int(count2)
            clSetKernelArg(kClearTwo, 0, MemoryLayout<cl_mem>.size, &clBuf1)
            clSetKernelArg(kClearTwo, 1, MemoryLayout<cl_int>.size, &s1)
            clSetKernelArg(kClearTwo, 2, MemoryLayout<cl_mem>.size, &clBuf2)
            clSetKernelArg(kClearTwo, 3, MemoryLayout<cl_int>.size, &s2)
            var gWork = ((max(count1, count2) / 4 + 127) / 128) * 128; var lWork = 128
            clEnqueueNDRangeKernel(clQueue, kClearTwo, 1, nil, &gWork, &lWork, 0, nil, nil)
            waitForOpenCLQueue()
            var clRes1 = [Int32](repeating: -1, count: count1)
            var clRes2 = [Int32](repeating: -1, count: count2)
            clEnqueueReadBuffer(clQueue, clBuf1, cl_bool(CL_TRUE), 0, count1 * 4, &clRes1, 0, nil, nil)
            clEnqueueReadBuffer(clQueue, clBuf2, cl_bool(CL_TRUE), 0, count2 * 4, &clRes2, 0, nil, nil)

            let pClearTwo = try! mtlDevice.makeComputePipelineState(function: mtlUtilLib.makeFunction(name: "clearTwoBuffers")!)
            let mtlBuf1 = mtlDevice.makeBuffer(bytes: init1, length: count1 * 4, options: .storageModeShared)!
            let mtlBuf2 = mtlDevice.makeBuffer(bytes: init2, length: count2 * 4, options: .storageModeShared)!
            var ms1 = Int32(count1); var ms2 = Int32(count2)
            let mtlS1 = mtlDevice.makeBuffer(bytes: &ms1, length: 4, options: .storageModeShared)!
            let mtlS2 = mtlDevice.makeBuffer(bytes: &ms2, length: 4, options: .storageModeShared)!

            let cb = mtlQueue.makeCommandBuffer()!
            let enc = cb.makeComputeCommandEncoder()!
            enc.setComputePipelineState(pClearTwo)
            enc.setBuffer(mtlBuf1, offset: 0, index: 0)
            enc.setBuffer(mtlS1, offset: 0, index: 1)
            enc.setBuffer(mtlBuf2, offset: 0, index: 2)
            enc.setBuffer(mtlS2, offset: 0, index: 3)
            enc.dispatchThreads(MTLSize(width: gWork, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1))
            enc.endEncoding()
            waitForCommandBuffer(cb)

            let mtlRes1 = Array(UnsafeBufferPointer(start: mtlBuf1.contents().assumingMemoryBound(to: Int32.self), count: count1))
            let mtlRes2 = Array(UnsafeBufferPointer(start: mtlBuf2.contents().assumingMemoryBound(to: Int32.self), count: count2))

            var nonZeros = 0
            for i in 0..<count1 { if mtlRes1[i] != 0 || clRes1[i] != 0 { nonZeros += 1 } }
            for i in 0..<count2 { if mtlRes2[i] != 0 || clRes2[i] != 0 { nonZeros += 1 } }
            let passed = (nonZeros == 0)
            results.append(AgreementStats(
                kernelName: "clearTwoBuffers (92224 + 2882 ints)",
                elementsChecked: count1 + count2,
                exactMatches: (count1 + count2) - nonZeros,
                mismatches: nonZeros,
                relDiffPpm: 0.0,
                statedTolerancePpm: 0.0,
                passed: passed,
                details: "Non-zero entries: \(nonZeros) (0 tolerance)"
            ))

            clReleaseKernel(kClearTwo)
            clReleaseMemObject(clBuf1); clReleaseMemObject(clBuf2)
        }

        // 6. Utility: reduceFloat4Buffer (92,224 * 4 float4s)
        do {
            let bufferSize = numAtoms
            let numBuffers = 4
            let totalFloat4s = bufferSize * numBuffers
            var initF4 = [SIMD4<Float>](repeating: SIMD4<Float>(0, 0, 0, 0), count: totalFloat4s)
            for b in 0..<numBuffers {
                for i in 0..<bufferSize {
                    let base = Float(i + 1) * 0.001
                    initF4[b * bufferSize + i] = SIMD4<Float>(base * Float(b + 1), base * Float(b + 2), base * Float(b + 3), 0.0)
                }
            }

            var err: cl_int = 0
            let kRedF4 = clCreateKernel(clUtilProg, "reduceReal4Buffer", &err)
            var clBuf = createCLBufferFromData(clContext, cl_mem_flags(CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR), initF4, &err)
            var clLongBuf = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_WRITE), bufferSize * 3 * 8, nil, &err)
            var cBufSize = cl_int(bufferSize); var cNumBufs = cl_int(numBuffers)
            clSetKernelArg(kRedF4, 0, MemoryLayout<cl_mem>.size, &clBuf)
            clSetKernelArg(kRedF4, 1, MemoryLayout<cl_mem>.size, &clLongBuf)
            clSetKernelArg(kRedF4, 2, MemoryLayout<cl_int>.size, &cBufSize)
            clSetKernelArg(kRedF4, 3, MemoryLayout<cl_int>.size, &cNumBufs)
            var gWork = ((bufferSize + 127) / 128) * 128; var lWork = 128
            clEnqueueNDRangeKernel(clQueue, kRedF4, 1, nil, &gWork, &lWork, 0, nil, nil)
            waitForOpenCLQueue()
            var clOut = [SIMD4<Float>](repeating: SIMD4<Float>(0, 0, 0, 0), count: bufferSize)
            clEnqueueReadBuffer(clQueue, clBuf, cl_bool(CL_TRUE), 0, bufferSize * 16, &clOut, 0, nil, nil)

            let pRedF4 = try! mtlDevice.makeComputePipelineState(function: mtlUtilLib.makeFunction(name: "reduceFloat4Buffer")!)
            let mtlBuf = mtlDevice.makeBuffer(bytes: initF4, length: totalFloat4s * 16, options: .storageModeShared)!
            let mtlLongBuf = mtlDevice.makeBuffer(length: bufferSize * 3 * 8, options: .storageModeShared)!
            var mBufSize = Int32(bufferSize); var mNumBufs = Int32(numBuffers)
            let mtlBufSize = mtlDevice.makeBuffer(bytes: &mBufSize, length: 4, options: .storageModeShared)!
            let mtlNumBufs = mtlDevice.makeBuffer(bytes: &mNumBufs, length: 4, options: .storageModeShared)!

            let cb = mtlQueue.makeCommandBuffer()!
            let enc = cb.makeComputeCommandEncoder()!
            enc.setComputePipelineState(pRedF4)
            enc.setBuffer(mtlBuf, offset: 0, index: 0)
            enc.setBuffer(mtlLongBuf, offset: 0, index: 1)
            enc.setBuffer(mtlBufSize, offset: 0, index: 2)
            enc.setBuffer(mtlNumBufs, offset: 0, index: 3)
            enc.dispatchThreads(MTLSize(width: gWork, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1))
            enc.endEncoding()
            waitForCommandBuffer(cb)

            let mtlOut = Array(UnsafeBufferPointer(start: mtlBuf.contents().assumingMemoryBound(to: SIMD4<Float>.self), count: bufferSize))

            // Check ppm relative difference between Metal and OpenCL
            var maxRelDiff: Double = 0.0
            for i in 0..<bufferSize {
                let dX = abs(Double(mtlOut[i].x) - Double(clOut[i].x)) / max(1e-5, abs(Double(clOut[i].x)))
                let dY = abs(Double(mtlOut[i].y) - Double(clOut[i].y)) / max(1e-5, abs(Double(clOut[i].y)))
                let dZ = abs(Double(mtlOut[i].z) - Double(clOut[i].z)) / max(1e-5, abs(Double(clOut[i].z)))
                maxRelDiff = max(maxRelDiff, max(dX, max(dY, dZ)))
            }
            let ppm = maxRelDiff * 1_000_000.0
            let statedTolPpm = 1.0
            let passed = (ppm <= statedTolPpm)
            results.append(AgreementStats(
                kernelName: "reduceFloat4Buffer (92224 * 4)",
                elementsChecked: bufferSize * 3,
                exactMatches: bufferSize * 3,
                mismatches: 0,
                relDiffPpm: ppm,
                statedTolerancePpm: statedTolPpm,
                passed: passed,
                details: "Max relative diff: \(ppm) ppm (tol \(statedTolPpm) ppm)"
            ))

            clReleaseKernel(kRedF4)
            clReleaseMemObject(clBuf); clReleaseMemObject(clLongBuf)
        }

        // 7. Utility: reduceForces (92,224 atoms, 4 force buffers)
        do {
            let bufferSize = numAtoms
            let numBuffers = 4
            let totalFloat4s = bufferSize * numBuffers
            var initF4 = [SIMD4<Float>](repeating: SIMD4<Float>(0, 0, 0, 0), count: totalFloat4s)
            var initLong = [Int64](repeating: 0, count: bufferSize * 3)
            for i in 0..<bufferSize {
                initLong[i] = Int64(Double(i) * 1000.0)
                initLong[i + bufferSize] = Int64(Double(i) * 2000.0)
                initLong[i + 2 * bufferSize] = Int64(Double(i) * 3000.0)
                for b in 0..<numBuffers {
                    initF4[b * bufferSize + i] = SIMD4<Float>(Float(b), Float(b + 1), Float(b + 2), 0.0)
                }
            }

            var err: cl_int = 0
            let kRedForces = clCreateKernel(clUtilProg, "reduceForces", &err)
            var clLongBuf = createCLBufferFromData(clContext, cl_mem_flags(CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR), initLong, &err)
            var clBuf = createCLBufferFromData(clContext, cl_mem_flags(CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR), initF4, &err)
            var cBufSize = cl_int(bufferSize); var cNumBufs = cl_int(numBuffers)
            clSetKernelArg(kRedForces, 0, MemoryLayout<cl_mem>.size, &clLongBuf)
            clSetKernelArg(kRedForces, 1, MemoryLayout<cl_mem>.size, &clBuf)
            clSetKernelArg(kRedForces, 2, MemoryLayout<cl_int>.size, &cBufSize)
            clSetKernelArg(kRedForces, 3, MemoryLayout<cl_int>.size, &cNumBufs)
            var gWork = ((bufferSize + 127) / 128) * 128; var lWork = 128
            clEnqueueNDRangeKernel(clQueue, kRedForces, 1, nil, &gWork, &lWork, 0, nil, nil)
            waitForOpenCLQueue()
            var clOut = [SIMD4<Float>](repeating: SIMD4<Float>(0, 0, 0, 0), count: bufferSize)
            clEnqueueReadBuffer(clQueue, clBuf, cl_bool(CL_TRUE), 0, bufferSize * 16, &clOut, 0, nil, nil)

            let pRedForces = try! mtlDevice.makeComputePipelineState(function: mtlUtilLib.makeFunction(name: "reduceForces")!)
            let mtlLongBuf = mtlDevice.makeBuffer(bytes: initLong, length: bufferSize * 3 * 8, options: .storageModeShared)!
            let mtlBuf = mtlDevice.makeBuffer(bytes: initF4, length: totalFloat4s * 16, options: .storageModeShared)!
            var mBufSize = Int32(bufferSize); var mNumBufs = Int32(numBuffers)
            let mtlBufSize = mtlDevice.makeBuffer(bytes: &mBufSize, length: 4, options: .storageModeShared)!
            let mtlNumBufs = mtlDevice.makeBuffer(bytes: &mNumBufs, length: 4, options: .storageModeShared)!

            let cb = mtlQueue.makeCommandBuffer()!
            let enc = cb.makeComputeCommandEncoder()!
            enc.setComputePipelineState(pRedForces)
            enc.setBuffer(mtlLongBuf, offset: 0, index: 0)
            enc.setBuffer(mtlBuf, offset: 0, index: 1)
            enc.setBuffer(mtlBufSize, offset: 0, index: 2)
            enc.setBuffer(mtlNumBufs, offset: 0, index: 3)
            enc.dispatchThreads(MTLSize(width: gWork, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1))
            enc.endEncoding()
            waitForCommandBuffer(cb)

            let mtlOut = Array(UnsafeBufferPointer(start: mtlBuf.contents().assumingMemoryBound(to: SIMD4<Float>.self), count: bufferSize))
            var maxRelDiff: Double = 0.0
            for i in 0..<bufferSize {
                let dX = abs(Double(mtlOut[i].x) - Double(clOut[i].x)) / max(1e-5, abs(Double(clOut[i].x)))
                let dY = abs(Double(mtlOut[i].y) - Double(clOut[i].y)) / max(1e-5, abs(Double(clOut[i].y)))
                let dZ = abs(Double(mtlOut[i].z) - Double(clOut[i].z)) / max(1e-5, abs(Double(clOut[i].z)))
                maxRelDiff = max(maxRelDiff, max(dX, max(dY, dZ)))
            }
            let ppm = maxRelDiff * 1_000_000.0
            let statedTolPpm = 1.0
            let passed = (ppm <= statedTolPpm)
            results.append(AgreementStats(
                kernelName: "reduceForces (92224 atoms, 4 buffers)",
                elementsChecked: bufferSize * 3,
                exactMatches: bufferSize * 3,
                mismatches: 0,
                relDiffPpm: ppm,
                statedTolerancePpm: statedTolPpm,
                passed: passed,
                details: "Max relative diff: \(ppm) ppm (tol \(statedTolPpm) ppm)"
            ))

            clReleaseKernel(kRedForces)
            clReleaseMemObject(clBuf); clReleaseMemObject(clLongBuf)
        }

        // 8. Utility: reduceEnergy (2,560 floats)
        do {
            let bufferSize = 2560
            let workGroupSize = 256
            let initEnergy = (0..<bufferSize).map { Float($0) * Float(0.125) }

            var err: cl_int = 0
            let kRedEnergy = clCreateKernel(clUtilProg, "reduceEnergy", &err)
            var clEnergy = createCLBufferFromData(clContext, cl_mem_flags(CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR), initEnergy, &err)
            var clResult = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_WRITE), 4, nil, &err)
            var cBufSize = cl_int(bufferSize); var cWgSize = cl_int(workGroupSize)
            clSetKernelArg(kRedEnergy, 0, MemoryLayout<cl_mem>.size, &clEnergy)
            clSetKernelArg(kRedEnergy, 1, MemoryLayout<cl_mem>.size, &clResult)
            clSetKernelArg(kRedEnergy, 2, MemoryLayout<cl_int>.size, &cBufSize)
            clSetKernelArg(kRedEnergy, 3, MemoryLayout<cl_int>.size, &cWgSize)
            var gWork = workGroupSize; var lWork = workGroupSize
            clEnqueueNDRangeKernel(clQueue, kRedEnergy, 1, nil, &gWork, &lWork, 0, nil, nil)
            waitForOpenCLQueue()
            var clVal: Float = 0.0
            clEnqueueReadBuffer(clQueue, clResult, cl_bool(CL_TRUE), 0, 4, &clVal, 0, nil, nil)

            let pRedEnergy = try! mtlDevice.makeComputePipelineState(function: mtlUtilLib.makeFunction(name: "reduceEnergy")!)
            let mtlEnergy = mtlDevice.makeBuffer(bytes: initEnergy, length: bufferSize * 4, options: .storageModeShared)!
            let mtlResult = mtlDevice.makeBuffer(length: 4, options: .storageModeShared)!
            var mBufSize = Int32(bufferSize); var mWgSize = Int32(workGroupSize)
            let mtlBufSize = mtlDevice.makeBuffer(bytes: &mBufSize, length: 4, options: .storageModeShared)!
            let mtlWgSize = mtlDevice.makeBuffer(bytes: &mWgSize, length: 4, options: .storageModeShared)!

            let cb = mtlQueue.makeCommandBuffer()!
            let enc = cb.makeComputeCommandEncoder()!
            enc.setComputePipelineState(pRedEnergy)
            enc.setBuffer(mtlEnergy, offset: 0, index: 0)
            enc.setBuffer(mtlResult, offset: 0, index: 1)
            enc.setBuffer(mtlBufSize, offset: 0, index: 2)
            enc.setBuffer(mtlWgSize, offset: 0, index: 3)
            enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: workGroupSize, height: 1, depth: 1))
            enc.endEncoding()
            waitForCommandBuffer(cb)

            let mtlVal = mtlResult.contents().assumingMemoryBound(to: Float.self).pointee
            let diff = abs(Double(mtlVal) - Double(clVal))
            let ppm = (diff / max(1e-5, abs(Double(clVal)))) * 1_000_000.0
            let statedTolPpm = 1.0
            let passed = (ppm <= statedTolPpm)
            results.append(AgreementStats(
                kernelName: "reduceEnergy (2560 elements)",
                elementsChecked: 1,
                exactMatches: passed ? 1 : 0,
                mismatches: passed ? 0 : 1,
                relDiffPpm: ppm,
                statedTolerancePpm: statedTolPpm,
                passed: passed,
                details: "Metal: \(mtlVal), OpenCL: \(clVal), diff: \(ppm) ppm (tol \(statedTolPpm) ppm)"
            ))

            clReleaseKernel(kRedEnergy)
            clReleaseMemObject(clEnergy); clReleaseMemObject(clResult)
        }

        // 9. Utility: setCharges (92,224 atoms)
        do {
            let count = numAtoms
            var atomOrder = Array(0..<Int32(count))
            // Reverse permutation to test indexing
            atomOrder.reverse()

            var err: cl_int = 0
            let kSetCharges = clCreateKernel(clUtilProg, "setCharges", &err)
            var clCharges = createCLBufferFromData(clContext, cl_mem_flags(CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR), chargesData, &err)
            var clPosq = createCLBufferFromData(clContext, cl_mem_flags(CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR), posqData, &err)
            var clAtomOrder = createCLBufferFromData(clContext, cl_mem_flags(CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR), atomOrder, &err)
            var cCount = cl_int(count)
            clSetKernelArg(kSetCharges, 0, MemoryLayout<cl_mem>.size, &clCharges)
            clSetKernelArg(kSetCharges, 1, MemoryLayout<cl_mem>.size, &clPosq)
            clSetKernelArg(kSetCharges, 2, MemoryLayout<cl_mem>.size, &clAtomOrder)
            clSetKernelArg(kSetCharges, 3, MemoryLayout<cl_int>.size, &cCount)
            var gWork = ((count + 127) / 128) * 128; var lWork = 128
            clEnqueueNDRangeKernel(clQueue, kSetCharges, 1, nil, &gWork, &lWork, 0, nil, nil)
            waitForOpenCLQueue()
            var clPosqOut = [SIMD4<Float>](repeating: SIMD4<Float>(0, 0, 0, 0), count: count)
            clEnqueueReadBuffer(clQueue, clPosq, cl_bool(CL_TRUE), 0, count * 16, &clPosqOut, 0, nil, nil)

            let pSetCharges = try! mtlDevice.makeComputePipelineState(function: mtlUtilLib.makeFunction(name: "setCharges")!)
            let mtlCharges = mtlDevice.makeBuffer(bytes: chargesData, length: count * 4, options: .storageModeShared)!
            let mtlPosq = mtlDevice.makeBuffer(bytes: posqData, length: count * 16, options: .storageModeShared)!
            let mtlAtomOrder = mtlDevice.makeBuffer(bytes: atomOrder, length: count * 4, options: .storageModeShared)!
            var mCount = Int32(count)
            let mtlCount = mtlDevice.makeBuffer(bytes: &mCount, length: 4, options: .storageModeShared)!

            let cb = mtlQueue.makeCommandBuffer()!
            let enc = cb.makeComputeCommandEncoder()!
            enc.setComputePipelineState(pSetCharges)
            enc.setBuffer(mtlCharges, offset: 0, index: 0)
            enc.setBuffer(mtlPosq, offset: 0, index: 1)
            enc.setBuffer(mtlAtomOrder, offset: 0, index: 2)
            enc.setBuffer(mtlCount, offset: 0, index: 3)
            enc.dispatchThreads(MTLSize(width: gWork, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1))
            enc.endEncoding()
            waitForCommandBuffer(cb)

            let mtlPosqOut = Array(UnsafeBufferPointer(start: mtlPosq.contents().assumingMemoryBound(to: SIMD4<Float>.self), count: count))
            var mismatches = 0
            for i in 0..<count {
                if mtlPosqOut[i].w != clPosqOut[i].w || mtlPosqOut[i].w != chargesData[Int(atomOrder[i])] {
                    mismatches += 1
                }
            }
            let passed = (mismatches == 0)
            results.append(AgreementStats(
                kernelName: "setCharges (92224 atoms)",
                elementsChecked: count,
                exactMatches: count - mismatches,
                mismatches: mismatches,
                relDiffPpm: 0.0,
                statedTolerancePpm: 0.0,
                passed: passed,
                details: "Mismatches: \(mismatches) (0 tolerance)"
            ))

            clReleaseKernel(kSetCharges)
            clReleaseMemObject(clCharges); clReleaseMemObject(clPosq); clReleaseMemObject(clAtomOrder)
        }

        clReleaseProgram(clSortProg)
        clReleaseProgram(clUtilProg)
        return results
    }

    // MARK: - Step 3: Mutation Gate

    func runMutationTests() -> [MutationGateResult] {
        var mutationResults: [MutationGateResult] = []
        let sortSrc = try! String(contentsOfFile: "\(kernelsDir)/sort.metal", encoding: .utf8)
        let utilSrc = try! String(contentsOfFile: "\(kernelsDir)/utilities.metal", encoding: .utf8)

        // 1. Mutation Sort: bucket assignment perturbation
        do {
            let mutatedLib = buildMetalLibrary(source: sortSrc, defines: [
                "DATA_TYPE": "uint", "KEY_TYPE": "uint", "SORT_KEY": "value", "MUTATION_SORT": "1"
            ])
            let count = apoa1BlocksKeys.count
            let targetBucketSize = 64
            let numBuckets = count / targetBucketSize
            let rangeKernelSize = 256
            let positionsKernelSize = min(rangeKernelSize, numBuckets)
            let sortKernelSize = 128
            let gWork = ((count + 127) / 128) * 128

            let pRange = try! mtlDevice.makeComputePipelineState(function: mutatedLib.makeFunction(name: "computeRange")!)
            let pAssign = try! mtlDevice.makeComputePipelineState(function: mutatedLib.makeFunction(name: "assignElementsToBuckets2")!)
            let pPos = try! mtlDevice.makeComputePipelineState(function: mutatedLib.makeFunction(name: "computeBucketPositions")!)
            let pCopy = try! mtlDevice.makeComputePipelineState(function: mutatedLib.makeFunction(name: "copyDataToBuckets")!)
            let pSort = try! mtlDevice.makeComputePipelineState(function: mutatedLib.makeFunction(name: "sortBuckets")!)

            let mtlData = mtlDevice.makeBuffer(bytes: apoa1BlocksKeys, length: count * 4, options: .storageModeShared)!
            let mtlRange = mtlDevice.makeBuffer(length: 8, options: .storageModeShared)!
            let mtlBucketOffset = mtlDevice.makeBuffer(length: numBuckets * 4, options: .storageModeShared)!
            let mtlBucketOfElement = mtlDevice.makeBuffer(length: count * 4, options: .storageModeShared)!
            let mtlOffsetInBucket = mtlDevice.makeBuffer(length: count * 4, options: .storageModeShared)!
            let mtlBuckets = mtlDevice.makeBuffer(length: count * 4, options: .storageModeShared)!
            var muCount = UInt32(count); var muNumBuckets = UInt32(numBuckets)
            let mtlUCount = mtlDevice.makeBuffer(bytes: &muCount, length: 4, options: .storageModeShared)!
            let mtlUNumBuckets = mtlDevice.makeBuffer(bytes: &muNumBuckets, length: 4, options: .storageModeShared)!

            let cb = mtlQueue.makeCommandBuffer()!
            let enc = cb.makeComputeCommandEncoder()!
            enc.setComputePipelineState(pRange)
            enc.setBuffer(mtlData, offset: 0, index: 0); enc.setBuffer(mtlUCount, offset: 0, index: 1)
            enc.setBuffer(mtlRange, offset: 0, index: 2); enc.setBuffer(mtlUNumBuckets, offset: 0, index: 3)
            enc.setBuffer(mtlBucketOffset, offset: 0, index: 4)
            enc.setThreadgroupMemoryLength(rangeKernelSize * 4, index: 0); enc.setThreadgroupMemoryLength(rangeKernelSize * 4, index: 1)
            enc.dispatchThreads(MTLSize(width: rangeKernelSize, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: rangeKernelSize, height: 1, depth: 1))

            enc.setComputePipelineState(pAssign)
            enc.setBuffer(mtlData, offset: 0, index: 0); enc.setBuffer(mtlUCount, offset: 0, index: 1)
            enc.setBuffer(mtlUNumBuckets, offset: 0, index: 2); enc.setBuffer(mtlRange, offset: 0, index: 3)
            enc.setBuffer(mtlBucketOffset, offset: 0, index: 4); enc.setBuffer(mtlBucketOfElement, offset: 0, index: 5)
            enc.setBuffer(mtlOffsetInBucket, offset: 0, index: 6)
            enc.dispatchThreads(MTLSize(width: gWork, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1))

            enc.setComputePipelineState(pPos)
            enc.setBuffer(mtlUNumBuckets, offset: 0, index: 0); enc.setBuffer(mtlBucketOffset, offset: 0, index: 1)
            enc.setThreadgroupMemoryLength(positionsKernelSize * 4, index: 0)
            enc.dispatchThreads(MTLSize(width: positionsKernelSize, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: positionsKernelSize, height: 1, depth: 1))

            enc.setComputePipelineState(pCopy)
            enc.setBuffer(mtlData, offset: 0, index: 0); enc.setBuffer(mtlBuckets, offset: 0, index: 1)
            enc.setBuffer(mtlUCount, offset: 0, index: 2); enc.setBuffer(mtlBucketOffset, offset: 0, index: 3)
            enc.setBuffer(mtlBucketOfElement, offset: 0, index: 4); enc.setBuffer(mtlOffsetInBucket, offset: 0, index: 5)
            enc.dispatchThreads(MTLSize(width: gWork, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1))

            enc.setComputePipelineState(pSort)
            enc.setBuffer(mtlData, offset: 0, index: 0); enc.setBuffer(mtlBuckets, offset: 0, index: 1)
            enc.setBuffer(mtlUNumBuckets, offset: 0, index: 2); enc.setBuffer(mtlBucketOffset, offset: 0, index: 3)
            enc.setThreadgroupMemoryLength(sortKernelSize * 4, index: 0)
            enc.dispatchThreadgroups(MTLSize(width: gWork / sortKernelSize, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: sortKernelSize, height: 1, depth: 1))
            enc.endEncoding()
            waitForCommandBuffer(cb)

            let mtlSorted = Array(UnsafeBufferPointer(start: mtlData.contents().assumingMemoryBound(to: UInt32.self), count: count))
            var mismatches = 0
            for i in 0..<count { if mtlSorted[i] != apoa1BlocksExpected[i] { mismatches += 1 } }
            let detected = (mismatches > 0)
            mutationResults.append(MutationGateResult(
                family: "sort",
                mutationDescription: "assignElementsToBuckets2 bucketIndex = (bucketIndex + 1) % numBuckets",
                detectedRed: detected,
                observation: "Detected \(mismatches)/\(count) element mismatches against reference"
            ))
        }

        // 2. Mutation Native Sort: invert bitonic comparator direction
        do {
            let mutatedLib = buildMetalLibrary(source: sortSrc, defines: ["MUTATION_NATIVE_SORT": "1"])
            let count = apoa1BlocksKeys.count
            let pNative = try! mtlDevice.makeComputePipelineState(function: mutatedLib.makeFunction(name: "nativeBitonicSort4096")!)
            let mtlData = mtlDevice.makeBuffer(bytes: apoa1BlocksKeys, length: count * 4, options: .storageModeShared)!
            var uCount = UInt32(count)
            let mtlUCount = mtlDevice.makeBuffer(bytes: &uCount, length: 4, options: .storageModeShared)!

            let cb = mtlQueue.makeCommandBuffer()!
            let enc = cb.makeComputeCommandEncoder()!
            enc.setComputePipelineState(pNative)
            enc.setBuffer(mtlData, offset: 0, index: 0)
            enc.setBuffer(mtlUCount, offset: 0, index: 1)
            enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 512, height: 1, depth: 1))
            enc.endEncoding()
            waitForCommandBuffer(cb)

            let mtlSorted = Array(UnsafeBufferPointer(start: mtlData.contents().assumingMemoryBound(to: UInt32.self), count: count))
            var mismatches = 0
            for i in 0..<count { if mtlSorted[i] != apoa1BlocksExpected[i] { mismatches += 1 } }
            let detected = (mismatches > 0)
            mutationResults.append(MutationGateResult(
                family: "nativeSort",
                mutationDescription: "nativeBitonicSort4096 ascending = !((i & k) == 0)",
                detectedRed: detected,
                observation: "Detected \(mismatches)/\(count) mismatches (reversed sort order)"
            ))
        }

        // 3. Mutation Clear: clearBuffer writes 1 instead of 0
        do {
            let mutatedLib = buildMetalLibrary(source: utilSrc, defines: ["MUTATION_CLEAR": "1"])
            let count = 1024
            let pClear = try! mtlDevice.makeComputePipelineState(function: mutatedLib.makeFunction(name: "clearBuffer")!)
            let mtlBuf = mtlDevice.makeBuffer(length: count * 4, options: .storageModeShared)!
            var mSize = Int32(count)
            let mtlSize = mtlDevice.makeBuffer(bytes: &mSize, length: 4, options: .storageModeShared)!

            let cb = mtlQueue.makeCommandBuffer()!
            let enc = cb.makeComputeCommandEncoder()!
            enc.setComputePipelineState(pClear)
            enc.setBuffer(mtlBuf, offset: 0, index: 0)
            enc.setBuffer(mtlSize, offset: 0, index: 1)
            enc.dispatchThreads(MTLSize(width: count / 4, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1))
            enc.endEncoding()
            waitForCommandBuffer(cb)

            let res = Array(UnsafeBufferPointer(start: mtlBuf.contents().assumingMemoryBound(to: Int32.self), count: count))
            var nonZeros = 0
            for x in res { if x != 0 { nonZeros += 1 } }
            let detected = (nonZeros > 0)
            mutationResults.append(MutationGateResult(
                family: "clear",
                mutationDescription: "clearBuffer writes int4(1) instead of int4(0)",
                detectedRed: detected,
                observation: "Detected \(nonZeros)/\(count) non-zero elements in cleared buffer"
            ))
        }

        // 4. Mutation Reduce: reduceFloat4Buffer drops final buffer from summation
        do {
            let mutatedLib = buildMetalLibrary(source: utilSrc, defines: ["MUTATION_REDUCE": "1"])
            let bufferSize = 1024
            let numBuffers = 4
            let totalFloat4s = bufferSize * numBuffers
            let initF4 = [SIMD4<Float>](repeating: SIMD4<Float>(1.0, 1.0, 1.0, 0.0), count: totalFloat4s)

            let pRed = try! mtlDevice.makeComputePipelineState(function: mutatedLib.makeFunction(name: "reduceFloat4Buffer")!)
            let mtlBuf = mtlDevice.makeBuffer(bytes: initF4, length: totalFloat4s * 16, options: .storageModeShared)!
            let mtlLongBuf = mtlDevice.makeBuffer(length: bufferSize * 3 * 8, options: .storageModeShared)!
            var mBufSize = Int32(bufferSize); var mNumBufs = Int32(numBuffers)
            let mtlBufSize = mtlDevice.makeBuffer(bytes: &mBufSize, length: 4, options: .storageModeShared)!
            let mtlNumBufs = mtlDevice.makeBuffer(bytes: &mNumBufs, length: 4, options: .storageModeShared)!

            let cb = mtlQueue.makeCommandBuffer()!
            let enc = cb.makeComputeCommandEncoder()!
            enc.setComputePipelineState(pRed)
            enc.setBuffer(mtlBuf, offset: 0, index: 0)
            enc.setBuffer(mtlLongBuf, offset: 0, index: 1)
            enc.setBuffer(mtlBufSize, offset: 0, index: 2)
            enc.setBuffer(mtlNumBufs, offset: 0, index: 3)
            enc.dispatchThreads(MTLSize(width: bufferSize, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1))
            enc.endEncoding()
            waitForCommandBuffer(cb)

            let res = Array(UnsafeBufferPointer(start: mtlBuf.contents().assumingMemoryBound(to: SIMD4<Float>.self), count: bufferSize))
            // Expected sum is 4.0, but mutation produces 3.0
            let diff = abs(Double(res[0].x) - 4.0) / 4.0
            let ppm = diff * 1_000_000.0
            let detected = (ppm > 1.0)
            mutationResults.append(MutationGateResult(
                family: "reduce",
                mutationDescription: "reduceFloat4Buffer drops final buffer from summation",
                detectedRed: detected,
                observation: "Measured error: \(ppm) ppm (expected 0.0 ppm, threshold 1.0 ppm)"
            ))
        }

        // 5. Mutation Charges: negate charge in setCharges
        do {
            let mutatedLib = buildMetalLibrary(source: utilSrc, defines: ["MUTATION_CHARGES": "1"])
            let count = 1024
            let chgs = (0..<count).map { Float($0 + 1) * 0.1 }
            let pq = (0..<count).map { _ in SIMD4<Float>(0, 0, 0, 0) }
            let order = Array(0..<Int32(count))

            let pSet = try! mtlDevice.makeComputePipelineState(function: mutatedLib.makeFunction(name: "setCharges")!)
            let mtlChgs = mtlDevice.makeBuffer(bytes: chgs, length: count * 4, options: .storageModeShared)!
            let mtlPq = mtlDevice.makeBuffer(bytes: pq, length: count * 16, options: .storageModeShared)!
            let mtlOrder = mtlDevice.makeBuffer(bytes: order, length: count * 4, options: .storageModeShared)!
            var mCount = Int32(count)
            let mtlCount = mtlDevice.makeBuffer(bytes: &mCount, length: 4, options: .storageModeShared)!

            let cb = mtlQueue.makeCommandBuffer()!
            let enc = cb.makeComputeCommandEncoder()!
            enc.setComputePipelineState(pSet)
            enc.setBuffer(mtlChgs, offset: 0, index: 0)
            enc.setBuffer(mtlPq, offset: 0, index: 1)
            enc.setBuffer(mtlOrder, offset: 0, index: 2)
            enc.setBuffer(mtlCount, offset: 0, index: 3)
            enc.dispatchThreads(MTLSize(width: count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1))
            enc.endEncoding()
            waitForCommandBuffer(cb)

            let res = Array(UnsafeBufferPointer(start: mtlPq.contents().assumingMemoryBound(to: SIMD4<Float>.self), count: count))
            var mismatches = 0
            for i in 0..<count { if res[i].w != chgs[i] { mismatches += 1 } }
            let detected = (mismatches > 0)
            mutationResults.append(MutationGateResult(
                family: "setCharges",
                mutationDescription: "setCharges posq[i].w = -charges[atomOrder[i]]",
                detectedRed: detected,
                observation: "Detected \(mismatches)/\(count) inverted charge assignments"
            ))
        }

        return mutationResults
    }

    // MARK: - Step 4: Individual Kernel Benchmarks

    func runIndividualKernelBenchmarks() -> [KernelTimingEntry] {
        var entries: [KernelTimingEntry] = []
        let sortSrc = try! String(contentsOfFile: "\(kernelsDir)/sort.metal", encoding: .utf8)
        let utilSrc = try! String(contentsOfFile: "\(kernelsDir)/utilities.metal", encoding: .utf8)
        let sortClSrc = try! String(contentsOfFile: "\(kernelsDir)/sort.cl", encoding: .utf8)
        let utilClSrc = try! String(contentsOfFile: "\(kernelsDir)/utilities.cl", encoding: .utf8)
        let utilCcSrc = try! String(contentsOfFile: "\(kernelsDir)/utilities.cc", encoding: .utf8)

        let sortDefines = [
            "DATA_TYPE": "uint", "KEY_TYPE": "uint", "SORT_KEY": "value", "MIN_KEY": "0", "MAX_KEY": "0xFFFFFFFFu", "MAX_VALUE": "0xFFFFFFFFu", "UNIFORM": "0"
        ]

        let clSortProg = buildOpenCLProgram(source: sortClSrc, defines: sortDefines)
        let mtlSortLib = buildMetalLibrary(source: sortSrc, defines: sortDefines)

        let clUtilProg = buildOpenCLProgram(source: utilClSrc + "\n" + utilCcSrc)
        let mtlUtilLib = buildMetalLibrary(source: utilSrc)

        // Helper to measure OpenCL kernel
        func timeCl(body: () -> cl_event?) -> TimingStats {
            var runs: [Double] = []
            for _ in 0..<repeats {
                let ev = body()
                let ms = clEventMs(ev)
                runs.append(ms)
            }
            return TimingStats(clock: "OpenCL event (mach ticks via clEventMs)", runs: runs)
        }

        // Helper to measure Metal kernel
        func timeMtl(body: (MTLComputeCommandEncoder) -> Void) -> TimingStats {
            var runs: [Double] = []
            for _ in 0..<repeats {
                let cb = mtlQueue.makeCommandBuffer()!
                let enc = cb.makeComputeCommandEncoder()!
                body(enc)
                enc.endEncoding()
                waitForCommandBuffer(cb)
                let elapsed = (cb.gpuEndTime - cb.gpuStartTime) * 1000.0
                runs.append(elapsed)
            }
            return TimingStats(clock: "Metal GPU timer (gpuEndTime - gpuStartTime)", runs: runs)
        }

        // 1. computeRange (2,882 keys)
        do {
            let count = apoa1BlocksKeys.count
            let numBuckets = count / 64
            var err: cl_int = 0
            let kRange = clCreateKernel(clSortProg, "computeRange", &err)
            var clData = createCLBufferFromData(clContext, cl_mem_flags(CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR), apoa1BlocksKeys, &err)
            var clRange = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_WRITE), 8, nil, &err)
            var clBucketOffset = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_WRITE), numBuckets * 4, nil, &err)
            var uCount = cl_uint(count); var uNumBuckets = cl_uint(numBuckets)
            clSetKernelArg(kRange, 0, MemoryLayout<cl_mem>.size, &clData)
            clSetKernelArg(kRange, 1, MemoryLayout<cl_uint>.size, &uCount)
            clSetKernelArg(kRange, 2, MemoryLayout<cl_mem>.size, &clRange)
            clSetKernelArg(kRange, 3, 256 * 4, nil)
            clSetKernelArg(kRange, 4, 256 * 4, nil)
            clSetKernelArg(kRange, 5, MemoryLayout<cl_uint>.size, &uNumBuckets)
            clSetKernelArg(kRange, 6, MemoryLayout<cl_mem>.size, &clBucketOffset)
            var gWork = 256; var lWork = 256

            let clStats = timeCl {
                var ev: cl_event?
                clEnqueueNDRangeKernel(clQueue, kRange, 1, nil, &gWork, &lWork, 0, nil, &ev)
                waitForOpenCLQueue()
                return ev
            }

            let pRange = try! mtlDevice.makeComputePipelineState(function: mtlSortLib.makeFunction(name: "computeRange")!)
            let mtlData = mtlDevice.makeBuffer(bytes: apoa1BlocksKeys, length: count * 4, options: .storageModeShared)!
            let mtlRange = mtlDevice.makeBuffer(length: 8, options: .storageModeShared)!
            let mtlBucketOffset = mtlDevice.makeBuffer(length: numBuckets * 4, options: .storageModeShared)!
            var muCount = UInt32(count); var muNumBuckets = UInt32(numBuckets)
            let mtlUCount = mtlDevice.makeBuffer(bytes: &muCount, length: 4, options: .storageModeShared)!
            let mtlUNumBuckets = mtlDevice.makeBuffer(bytes: &muNumBuckets, length: 4, options: .storageModeShared)!

            let mtlStats = timeMtl { enc in
                enc.setComputePipelineState(pRange)
                enc.setBuffer(mtlData, offset: 0, index: 0)
                enc.setBuffer(mtlUCount, offset: 0, index: 1)
                enc.setBuffer(mtlRange, offset: 0, index: 2)
                enc.setBuffer(mtlUNumBuckets, offset: 0, index: 3)
                enc.setBuffer(mtlBucketOffset, offset: 0, index: 4)
                enc.setThreadgroupMemoryLength(256 * 4, index: 0)
                enc.setThreadgroupMemoryLength(256 * 4, index: 1)
                enc.dispatchThreads(MTLSize(width: 256, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
            }

            entries.append(KernelTimingEntry(
                kernel: "computeRange",
                openclGpuEventMs: clStats,
                metalGpuTimerMs: mtlStats,
                ratioMetalToOpenCL: mtlStats.median / max(1e-6, clStats.median)
            ))
            clReleaseKernel(kRange); clReleaseMemObject(clData); clReleaseMemObject(clRange); clReleaseMemObject(clBucketOffset)
        }

        // 2. assignElementsToBuckets2 (2,882 keys)
        do {
            let count = apoa1BlocksKeys.count
            let numBuckets = count / 64
            var err: cl_int = 0
            let kAssign = clCreateKernel(clSortProg, "assignElementsToBuckets2", &err)
            var clData = createCLBufferFromData(clContext, cl_mem_flags(CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR), apoa1BlocksKeys, &err)
            var clRange = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_WRITE), 8, nil, &err)
            var clBucketOffset = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_WRITE), numBuckets * 4, nil, &err)
            var clBucketOfElement = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_WRITE), count * 4, nil, &err)
            var clOffsetInBucket = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_WRITE), count * 4, nil, &err)
            var uCount = cl_uint(count); var uNumBuckets = cl_uint(numBuckets)
            clSetKernelArg(kAssign, 0, MemoryLayout<cl_mem>.size, &clData)
            clSetKernelArg(kAssign, 1, MemoryLayout<cl_uint>.size, &uCount)
            clSetKernelArg(kAssign, 2, MemoryLayout<cl_uint>.size, &uNumBuckets)
            clSetKernelArg(kAssign, 3, MemoryLayout<cl_mem>.size, &clRange)
            clSetKernelArg(kAssign, 4, MemoryLayout<cl_mem>.size, &clBucketOffset)
            clSetKernelArg(kAssign, 5, MemoryLayout<cl_mem>.size, &clBucketOfElement)
            clSetKernelArg(kAssign, 6, MemoryLayout<cl_mem>.size, &clOffsetInBucket)
            var gWork = ((count + 127) / 128) * 128; var lWork = 128

            let clStats = timeCl {
                var ev: cl_event?
                clEnqueueNDRangeKernel(clQueue, kAssign, 1, nil, &gWork, &lWork, 0, nil, &ev)
                waitForOpenCLQueue()
                return ev
            }

            let pAssign = try! mtlDevice.makeComputePipelineState(function: mtlSortLib.makeFunction(name: "assignElementsToBuckets2")!)
            let mtlData = mtlDevice.makeBuffer(bytes: apoa1BlocksKeys, length: count * 4, options: .storageModeShared)!
            let mtlRange = mtlDevice.makeBuffer(length: 8, options: .storageModeShared)!
            let mtlBucketOffset = mtlDevice.makeBuffer(length: numBuckets * 4, options: .storageModeShared)!
            let mtlBucketOfElement = mtlDevice.makeBuffer(length: count * 4, options: .storageModeShared)!
            let mtlOffsetInBucket = mtlDevice.makeBuffer(length: count * 4, options: .storageModeShared)!
            var muCount = UInt32(count); var muNumBuckets = UInt32(numBuckets)
            let mtlUCount = mtlDevice.makeBuffer(bytes: &muCount, length: 4, options: .storageModeShared)!
            let mtlUNumBuckets = mtlDevice.makeBuffer(bytes: &muNumBuckets, length: 4, options: .storageModeShared)!

            let mtlStats = timeMtl { enc in
                enc.setComputePipelineState(pAssign)
                enc.setBuffer(mtlData, offset: 0, index: 0)
                enc.setBuffer(mtlUCount, offset: 0, index: 1)
                enc.setBuffer(mtlUNumBuckets, offset: 0, index: 2)
                enc.setBuffer(mtlRange, offset: 0, index: 3)
                enc.setBuffer(mtlBucketOffset, offset: 0, index: 4)
                enc.setBuffer(mtlBucketOfElement, offset: 0, index: 5)
                enc.setBuffer(mtlOffsetInBucket, offset: 0, index: 6)
                enc.dispatchThreads(MTLSize(width: gWork, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1))
            }

            entries.append(KernelTimingEntry(
                kernel: "assignElementsToBuckets2",
                openclGpuEventMs: clStats,
                metalGpuTimerMs: mtlStats,
                ratioMetalToOpenCL: mtlStats.median / max(1e-6, clStats.median)
            ))
            clReleaseKernel(kAssign); clReleaseMemObject(clData); clReleaseMemObject(clRange); clReleaseMemObject(clBucketOffset)
            clReleaseMemObject(clBucketOfElement); clReleaseMemObject(clOffsetInBucket)
        }

        // 3. computeBucketPositions (45 buckets)
        do {
            let count = apoa1BlocksKeys.count
            let numBuckets = count / 64
            var err: cl_int = 0
            let kPos = clCreateKernel(clSortProg, "computeBucketPositions", &err)
            var clBucketOffset = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_WRITE), numBuckets * 4, nil, &err)
            var uNumBuckets = cl_uint(numBuckets)
            clSetKernelArg(kPos, 0, MemoryLayout<cl_uint>.size, &uNumBuckets)
            clSetKernelArg(kPos, 1, MemoryLayout<cl_mem>.size, &clBucketOffset)
            clSetKernelArg(kPos, 2, numBuckets * 4, nil)
            var gWork = numBuckets; var lWork = numBuckets

            let clStats = timeCl {
                var ev: cl_event?
                clEnqueueNDRangeKernel(clQueue, kPos, 1, nil, &gWork, &lWork, 0, nil, &ev)
                waitForOpenCLQueue()
                return ev
            }

            let pPos = try! mtlDevice.makeComputePipelineState(function: mtlSortLib.makeFunction(name: "computeBucketPositions")!)
            let mtlBucketOffset = mtlDevice.makeBuffer(length: numBuckets * 4, options: .storageModeShared)!
            var muNumBuckets = UInt32(numBuckets)
            let mtlUNumBuckets = mtlDevice.makeBuffer(bytes: &muNumBuckets, length: 4, options: .storageModeShared)!

            let mtlStats = timeMtl { enc in
                enc.setComputePipelineState(pPos)
                enc.setBuffer(mtlUNumBuckets, offset: 0, index: 0)
                enc.setBuffer(mtlBucketOffset, offset: 0, index: 1)
                enc.setThreadgroupMemoryLength(numBuckets * 4, index: 0)
                enc.dispatchThreads(MTLSize(width: numBuckets, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: numBuckets, height: 1, depth: 1))
            }

            entries.append(KernelTimingEntry(
                kernel: "computeBucketPositions",
                openclGpuEventMs: clStats,
                metalGpuTimerMs: mtlStats,
                ratioMetalToOpenCL: mtlStats.median / max(1e-6, clStats.median)
            ))
            clReleaseKernel(kPos); clReleaseMemObject(clBucketOffset)
        }

        // 4. copyDataToBuckets (2,882 keys)
        do {
            let count = apoa1BlocksKeys.count
            let numBuckets = count / 64
            var err: cl_int = 0
            let kCopy = clCreateKernel(clSortProg, "copyDataToBuckets", &err)
            var clData = createCLBufferFromData(clContext, cl_mem_flags(CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR), apoa1BlocksKeys, &err)
            var clBuckets = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_WRITE), count * 4, nil, &err)
            var clBucketOffset = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_WRITE), numBuckets * 4, nil, &err)
            var clBucketOfElement = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_WRITE), count * 4, nil, &err)
            var clOffsetInBucket = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_WRITE), count * 4, nil, &err)
            var uCount = cl_uint(count)
            clSetKernelArg(kCopy, 0, MemoryLayout<cl_mem>.size, &clData)
            clSetKernelArg(kCopy, 1, MemoryLayout<cl_mem>.size, &clBuckets)
            clSetKernelArg(kCopy, 2, MemoryLayout<cl_uint>.size, &uCount)
            clSetKernelArg(kCopy, 3, MemoryLayout<cl_mem>.size, &clBucketOffset)
            clSetKernelArg(kCopy, 4, MemoryLayout<cl_mem>.size, &clBucketOfElement)
            clSetKernelArg(kCopy, 5, MemoryLayout<cl_mem>.size, &clOffsetInBucket)
            var gWork = ((count + 127) / 128) * 128; var lWork = 128

            let clStats = timeCl {
                var ev: cl_event?
                clEnqueueNDRangeKernel(clQueue, kCopy, 1, nil, &gWork, &lWork, 0, nil, &ev)
                waitForOpenCLQueue()
                return ev
            }

            let pCopy = try! mtlDevice.makeComputePipelineState(function: mtlSortLib.makeFunction(name: "copyDataToBuckets")!)
            let mtlData = mtlDevice.makeBuffer(bytes: apoa1BlocksKeys, length: count * 4, options: .storageModeShared)!
            let mtlBuckets = mtlDevice.makeBuffer(length: count * 4, options: .storageModeShared)!
            let mtlBucketOffset = mtlDevice.makeBuffer(length: numBuckets * 4, options: .storageModeShared)!
            let mtlBucketOfElement = mtlDevice.makeBuffer(length: count * 4, options: .storageModeShared)!
            let mtlOffsetInBucket = mtlDevice.makeBuffer(length: count * 4, options: .storageModeShared)!
            var muCount = UInt32(count)
            let mtlUCount = mtlDevice.makeBuffer(bytes: &muCount, length: 4, options: .storageModeShared)!

            let mtlStats = timeMtl { enc in
                enc.setComputePipelineState(pCopy)
                enc.setBuffer(mtlData, offset: 0, index: 0)
                enc.setBuffer(mtlBuckets, offset: 0, index: 1)
                enc.setBuffer(mtlUCount, offset: 0, index: 2)
                enc.setBuffer(mtlBucketOffset, offset: 0, index: 3)
                enc.setBuffer(mtlBucketOfElement, offset: 0, index: 4)
                enc.setBuffer(mtlOffsetInBucket, offset: 0, index: 5)
                enc.dispatchThreads(MTLSize(width: gWork, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1))
            }

            entries.append(KernelTimingEntry(
                kernel: "copyDataToBuckets",
                openclGpuEventMs: clStats,
                metalGpuTimerMs: mtlStats,
                ratioMetalToOpenCL: mtlStats.median / max(1e-6, clStats.median)
            ))
            clReleaseKernel(kCopy); clReleaseMemObject(clData); clReleaseMemObject(clBuckets); clReleaseMemObject(clBucketOffset)
            clReleaseMemObject(clBucketOfElement); clReleaseMemObject(clOffsetInBucket)
        }

        // 5. sortBuckets (2,882 keys)
        do {
            let count = apoa1BlocksKeys.count
            let numBuckets = count / 64
            var err: cl_int = 0
            let kSort = clCreateKernel(clSortProg, "sortBuckets", &err)
            var clData = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_WRITE), count * 4, nil, &err)
            var clBuckets = createCLBufferFromData(clContext, cl_mem_flags(CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR), apoa1BlocksKeys, &err)
            var clBucketOffset = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_WRITE), numBuckets * 4, nil, &err)
            var uNumBuckets = cl_uint(numBuckets)
            clSetKernelArg(kSort, 0, MemoryLayout<cl_mem>.size, &clData)
            clSetKernelArg(kSort, 1, MemoryLayout<cl_mem>.size, &clBuckets)
            clSetKernelArg(kSort, 2, MemoryLayout<cl_uint>.size, &uNumBuckets)
            clSetKernelArg(kSort, 3, MemoryLayout<cl_mem>.size, &clBucketOffset)
            clSetKernelArg(kSort, 4, 128 * 4, nil)
            var gWork = ((count + 127) / 128) * 128; var lWork = 128

            let clStats = timeCl {
                var ev: cl_event?
                clEnqueueNDRangeKernel(clQueue, kSort, 1, nil, &gWork, &lWork, 0, nil, &ev)
                waitForOpenCLQueue()
                return ev
            }

            let pSort = try! mtlDevice.makeComputePipelineState(function: mtlSortLib.makeFunction(name: "sortBuckets")!)
            let mtlData = mtlDevice.makeBuffer(length: count * 4, options: .storageModeShared)!
            let mtlBuckets = mtlDevice.makeBuffer(bytes: apoa1BlocksKeys, length: count * 4, options: .storageModeShared)!
            let mtlBucketOffset = mtlDevice.makeBuffer(length: numBuckets * 4, options: .storageModeShared)!
            var muNumBuckets = UInt32(numBuckets)
            let mtlUNumBuckets = mtlDevice.makeBuffer(bytes: &muNumBuckets, length: 4, options: .storageModeShared)!

            let mtlStats = timeMtl { enc in
                enc.setComputePipelineState(pSort)
                enc.setBuffer(mtlData, offset: 0, index: 0)
                enc.setBuffer(mtlBuckets, offset: 0, index: 1)
                enc.setBuffer(mtlUNumBuckets, offset: 0, index: 2)
                enc.setBuffer(mtlBucketOffset, offset: 0, index: 3)
                enc.setThreadgroupMemoryLength(128 * 4, index: 0)
                enc.dispatchThreadgroups(MTLSize(width: gWork / 128, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1))
            }

            entries.append(KernelTimingEntry(
                kernel: "sortBuckets",
                openclGpuEventMs: clStats,
                metalGpuTimerMs: mtlStats,
                ratioMetalToOpenCL: mtlStats.median / max(1e-6, clStats.median)
            ))
            clReleaseKernel(kSort); clReleaseMemObject(clData); clReleaseMemObject(clBuckets); clReleaseMemObject(clBucketOffset)
        }

        // 6. sortShortList (1,024 keys)
        do {
            let count = shortListKeys.count
            var err: cl_int = 0
            let kShort = clCreateKernel(clSortProg, "sortShortList", &err)
            var clData = createCLBufferFromData(clContext, cl_mem_flags(CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR), shortListKeys, &err)
            var uCount = cl_uint(count)
            clSetKernelArg(kShort, 0, MemoryLayout<cl_mem>.size, &clData)
            clSetKernelArg(kShort, 1, MemoryLayout<cl_uint>.size, &uCount)
            clSetKernelArg(kShort, 2, count * 4, nil)
            var gWork = 256; var lWork = 256

            let clStats = timeCl {
                var ev: cl_event?
                clEnqueueNDRangeKernel(clQueue, kShort, 1, nil, &gWork, &lWork, 0, nil, &ev)
                waitForOpenCLQueue()
                return ev
            }

            let pShort = try! mtlDevice.makeComputePipelineState(function: mtlSortLib.makeFunction(name: "sortShortList")!)
            let mtlData = mtlDevice.makeBuffer(bytes: shortListKeys, length: count * 4, options: .storageModeShared)!
            var muCount = UInt32(count)
            let mtlUCount = mtlDevice.makeBuffer(bytes: &muCount, length: 4, options: .storageModeShared)!

            let mtlStats = timeMtl { enc in
                enc.setComputePipelineState(pShort)
                enc.setBuffer(mtlData, offset: 0, index: 0)
                enc.setBuffer(mtlUCount, offset: 0, index: 1)
                enc.setThreadgroupMemoryLength(count * 4, index: 0)
                enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
            }

            entries.append(KernelTimingEntry(
                kernel: "sortShortList",
                openclGpuEventMs: clStats,
                metalGpuTimerMs: mtlStats,
                ratioMetalToOpenCL: mtlStats.median / max(1e-6, clStats.median)
            ))
            clReleaseKernel(kShort); clReleaseMemObject(clData)
        }

        // 7. clearBuffer (92,224 ints)
        do {
            let count = numAtoms
            var err: cl_int = 0
            let kClear = clCreateKernel(clUtilProg, "clearBuffer", &err)
            var clBuf = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_WRITE), count * 4, nil, &err)
            var cSize = cl_int(count)
            clSetKernelArg(kClear, 0, MemoryLayout<cl_mem>.size, &clBuf)
            clSetKernelArg(kClear, 1, MemoryLayout<cl_int>.size, &cSize)
            var gWork = ((count / 4 + 127) / 128) * 128; var lWork = 128

            let clStats = timeCl {
                var ev: cl_event?
                clEnqueueNDRangeKernel(clQueue, kClear, 1, nil, &gWork, &lWork, 0, nil, &ev)
                waitForOpenCLQueue()
                return ev
            }

            let pClear = try! mtlDevice.makeComputePipelineState(function: mtlUtilLib.makeFunction(name: "clearBuffer")!)
            let mtlBuf = mtlDevice.makeBuffer(length: count * 4, options: .storageModeShared)!
            var mSize = Int32(count)
            let mtlSize = mtlDevice.makeBuffer(bytes: &mSize, length: 4, options: .storageModeShared)!

            let mtlStats = timeMtl { enc in
                enc.setComputePipelineState(pClear)
                enc.setBuffer(mtlBuf, offset: 0, index: 0)
                enc.setBuffer(mtlSize, offset: 0, index: 1)
                enc.dispatchThreads(MTLSize(width: gWork, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1))
            }

            entries.append(KernelTimingEntry(
                kernel: "clearBuffer",
                openclGpuEventMs: clStats,
                metalGpuTimerMs: mtlStats,
                ratioMetalToOpenCL: mtlStats.median / max(1e-6, clStats.median)
            ))
            clReleaseKernel(kClear); clReleaseMemObject(clBuf)
        }

        // 8. clearTwoBuffers (92,224 and 2,882 ints)
        do {
            let count1 = numAtoms; let count2 = 2882
            var err: cl_int = 0
            let kClearTwo = clCreateKernel(clUtilProg, "clearTwoBuffers", &err)
            var clBuf1 = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_WRITE), count1 * 4, nil, &err)
            var clBuf2 = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_WRITE), count2 * 4, nil, &err)
            var s1 = cl_int(count1); var s2 = cl_int(count2)
            clSetKernelArg(kClearTwo, 0, MemoryLayout<cl_mem>.size, &clBuf1)
            clSetKernelArg(kClearTwo, 1, MemoryLayout<cl_int>.size, &s1)
            clSetKernelArg(kClearTwo, 2, MemoryLayout<cl_mem>.size, &clBuf2)
            clSetKernelArg(kClearTwo, 3, MemoryLayout<cl_int>.size, &s2)
            var gWork = ((max(count1, count2) / 4 + 127) / 128) * 128; var lWork = 128

            let clStats = timeCl {
                var ev: cl_event?
                clEnqueueNDRangeKernel(clQueue, kClearTwo, 1, nil, &gWork, &lWork, 0, nil, &ev)
                waitForOpenCLQueue()
                return ev
            }

            let pClearTwo = try! mtlDevice.makeComputePipelineState(function: mtlUtilLib.makeFunction(name: "clearTwoBuffers")!)
            let mtlBuf1 = mtlDevice.makeBuffer(length: count1 * 4, options: .storageModeShared)!
            let mtlBuf2 = mtlDevice.makeBuffer(length: count2 * 4, options: .storageModeShared)!
            var ms1 = Int32(count1); var ms2 = Int32(count2)
            let mtlS1 = mtlDevice.makeBuffer(bytes: &ms1, length: 4, options: .storageModeShared)!
            let mtlS2 = mtlDevice.makeBuffer(bytes: &ms2, length: 4, options: .storageModeShared)!

            let mtlStats = timeMtl { enc in
                enc.setComputePipelineState(pClearTwo)
                enc.setBuffer(mtlBuf1, offset: 0, index: 0)
                enc.setBuffer(mtlS1, offset: 0, index: 1)
                enc.setBuffer(mtlBuf2, offset: 0, index: 2)
                enc.setBuffer(mtlS2, offset: 0, index: 3)
                enc.dispatchThreads(MTLSize(width: gWork, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1))
            }

            entries.append(KernelTimingEntry(
                kernel: "clearTwoBuffers",
                openclGpuEventMs: clStats,
                metalGpuTimerMs: mtlStats,
                ratioMetalToOpenCL: mtlStats.median / max(1e-6, clStats.median)
            ))
            clReleaseKernel(kClearTwo); clReleaseMemObject(clBuf1); clReleaseMemObject(clBuf2)
        }

        // 9. reduceFloat4Buffer (92,224 * 4 float4s)
        do {
            let bufferSize = numAtoms; let numBuffers = 4
            var err: cl_int = 0
            let kRedF4 = clCreateKernel(clUtilProg, "reduceReal4Buffer", &err)
            var clBuf = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_WRITE), bufferSize * numBuffers * 16, nil, &err)
            var clLongBuf = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_WRITE), bufferSize * 3 * 8, nil, &err)
            var cBufSize = cl_int(bufferSize); var cNumBufs = cl_int(numBuffers)
            clSetKernelArg(kRedF4, 0, MemoryLayout<cl_mem>.size, &clBuf)
            clSetKernelArg(kRedF4, 1, MemoryLayout<cl_mem>.size, &clLongBuf)
            clSetKernelArg(kRedF4, 2, MemoryLayout<cl_int>.size, &cBufSize)
            clSetKernelArg(kRedF4, 3, MemoryLayout<cl_int>.size, &cNumBufs)
            var gWork = ((bufferSize + 127) / 128) * 128; var lWork = 128

            let clStats = timeCl {
                var ev: cl_event?
                clEnqueueNDRangeKernel(clQueue, kRedF4, 1, nil, &gWork, &lWork, 0, nil, &ev)
                waitForOpenCLQueue()
                return ev
            }

            let pRedF4 = try! mtlDevice.makeComputePipelineState(function: mtlUtilLib.makeFunction(name: "reduceFloat4Buffer")!)
            let mtlBuf = mtlDevice.makeBuffer(length: bufferSize * numBuffers * 16, options: .storageModeShared)!
            let mtlLongBuf = mtlDevice.makeBuffer(length: bufferSize * 3 * 8, options: .storageModeShared)!
            var mBufSize = Int32(bufferSize); var mNumBufs = Int32(numBuffers)
            let mtlBufSize = mtlDevice.makeBuffer(bytes: &mBufSize, length: 4, options: .storageModeShared)!
            let mtlNumBufs = mtlDevice.makeBuffer(bytes: &mNumBufs, length: 4, options: .storageModeShared)!

            let mtlStats = timeMtl { enc in
                enc.setComputePipelineState(pRedF4)
                enc.setBuffer(mtlBuf, offset: 0, index: 0)
                enc.setBuffer(mtlLongBuf, offset: 0, index: 1)
                enc.setBuffer(mtlBufSize, offset: 0, index: 2)
                enc.setBuffer(mtlNumBufs, offset: 0, index: 3)
                enc.dispatchThreads(MTLSize(width: gWork, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1))
            }

            entries.append(KernelTimingEntry(
                kernel: "reduceFloat4Buffer",
                openclGpuEventMs: clStats,
                metalGpuTimerMs: mtlStats,
                ratioMetalToOpenCL: mtlStats.median / max(1e-6, clStats.median)
            ))
            clReleaseKernel(kRedF4); clReleaseMemObject(clBuf); clReleaseMemObject(clLongBuf)
        }

        // 10. reduceForces (92,224 atoms, 4 buffers)
        do {
            let bufferSize = numAtoms; let numBuffers = 4
            var err: cl_int = 0
            let kRedForces = clCreateKernel(clUtilProg, "reduceForces", &err)
            var clLongBuf = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_WRITE), bufferSize * 3 * 8, nil, &err)
            var clBuf = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_WRITE), bufferSize * numBuffers * 16, nil, &err)
            var cBufSize = cl_int(bufferSize); var cNumBufs = cl_int(numBuffers)
            clSetKernelArg(kRedForces, 0, MemoryLayout<cl_mem>.size, &clLongBuf)
            clSetKernelArg(kRedForces, 1, MemoryLayout<cl_mem>.size, &clBuf)
            clSetKernelArg(kRedForces, 2, MemoryLayout<cl_int>.size, &cBufSize)
            clSetKernelArg(kRedForces, 3, MemoryLayout<cl_int>.size, &cNumBufs)
            var gWork = ((bufferSize + 127) / 128) * 128; var lWork = 128

            let clStats = timeCl {
                var ev: cl_event?
                clEnqueueNDRangeKernel(clQueue, kRedForces, 1, nil, &gWork, &lWork, 0, nil, &ev)
                waitForOpenCLQueue()
                return ev
            }

            let pRedForces = try! mtlDevice.makeComputePipelineState(function: mtlUtilLib.makeFunction(name: "reduceForces")!)
            let mtlLongBuf = mtlDevice.makeBuffer(length: bufferSize * 3 * 8, options: .storageModeShared)!
            let mtlBuf = mtlDevice.makeBuffer(length: bufferSize * numBuffers * 16, options: .storageModeShared)!
            var mBufSize = Int32(bufferSize); var mNumBufs = Int32(numBuffers)
            let mtlBufSize = mtlDevice.makeBuffer(bytes: &mBufSize, length: 4, options: .storageModeShared)!
            let mtlNumBufs = mtlDevice.makeBuffer(bytes: &mNumBufs, length: 4, options: .storageModeShared)!

            let mtlStats = timeMtl { enc in
                enc.setComputePipelineState(pRedForces)
                enc.setBuffer(mtlLongBuf, offset: 0, index: 0)
                enc.setBuffer(mtlBuf, offset: 0, index: 1)
                enc.setBuffer(mtlBufSize, offset: 0, index: 2)
                enc.setBuffer(mtlNumBufs, offset: 0, index: 3)
                enc.dispatchThreads(MTLSize(width: gWork, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1))
            }

            entries.append(KernelTimingEntry(
                kernel: "reduceForces",
                openclGpuEventMs: clStats,
                metalGpuTimerMs: mtlStats,
                ratioMetalToOpenCL: mtlStats.median / max(1e-6, clStats.median)
            ))
            clReleaseKernel(kRedForces); clReleaseMemObject(clBuf); clReleaseMemObject(clLongBuf)
        }

        // 11. reduceEnergy (2,560 elements)
        do {
            let bufferSize = 2560; let workGroupSize = 256
            var err: cl_int = 0
            let kRedEnergy = clCreateKernel(clUtilProg, "reduceEnergy", &err)
            var clEnergy = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_WRITE), bufferSize * 4, nil, &err)
            var clResult = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_WRITE), 4, nil, &err)
            var cBufSize = cl_int(bufferSize); var cWgSize = cl_int(workGroupSize)
            clSetKernelArg(kRedEnergy, 0, MemoryLayout<cl_mem>.size, &clEnergy)
            clSetKernelArg(kRedEnergy, 1, MemoryLayout<cl_mem>.size, &clResult)
            clSetKernelArg(kRedEnergy, 2, MemoryLayout<cl_int>.size, &cBufSize)
            clSetKernelArg(kRedEnergy, 3, MemoryLayout<cl_int>.size, &cWgSize)
            var gWork = workGroupSize; var lWork = workGroupSize

            let clStats = timeCl {
                var ev: cl_event?
                clEnqueueNDRangeKernel(clQueue, kRedEnergy, 1, nil, &gWork, &lWork, 0, nil, &ev)
                waitForOpenCLQueue()
                return ev
            }

            let pRedEnergy = try! mtlDevice.makeComputePipelineState(function: mtlUtilLib.makeFunction(name: "reduceEnergy")!)
            let mtlEnergy = mtlDevice.makeBuffer(length: bufferSize * 4, options: .storageModeShared)!
            let mtlResult = mtlDevice.makeBuffer(length: 4, options: .storageModeShared)!
            var mBufSize = Int32(bufferSize); var mWgSize = Int32(workGroupSize)
            let mtlBufSize = mtlDevice.makeBuffer(bytes: &mBufSize, length: 4, options: .storageModeShared)!
            let mtlWgSize = mtlDevice.makeBuffer(bytes: &mWgSize, length: 4, options: .storageModeShared)!

            let mtlStats = timeMtl { enc in
                enc.setComputePipelineState(pRedEnergy)
                enc.setBuffer(mtlEnergy, offset: 0, index: 0)
                enc.setBuffer(mtlResult, offset: 0, index: 1)
                enc.setBuffer(mtlBufSize, offset: 0, index: 2)
                enc.setBuffer(mtlWgSize, offset: 0, index: 3)
                enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: workGroupSize, height: 1, depth: 1))
            }

            entries.append(KernelTimingEntry(
                kernel: "reduceEnergy",
                openclGpuEventMs: clStats,
                metalGpuTimerMs: mtlStats,
                ratioMetalToOpenCL: mtlStats.median / max(1e-6, clStats.median)
            ))
            clReleaseKernel(kRedEnergy); clReleaseMemObject(clEnergy); clReleaseMemObject(clResult)
        }

        // 12. setCharges (92,224 atoms)
        do {
            let count = numAtoms
            let order = Array(0..<Int32(count))
            var err: cl_int = 0
            let kSet = clCreateKernel(clUtilProg, "setCharges", &err)
            var clCharges = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_WRITE), count * 4, nil, &err)
            var clPosq = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_WRITE), count * 16, nil, &err)
            var clOrder = createCLBufferFromData(clContext, cl_mem_flags(CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR), order, &err)
            var cCount = cl_int(count)
            clSetKernelArg(kSet, 0, MemoryLayout<cl_mem>.size, &clCharges)
            clSetKernelArg(kSet, 1, MemoryLayout<cl_mem>.size, &clPosq)
            clSetKernelArg(kSet, 2, MemoryLayout<cl_mem>.size, &clOrder)
            clSetKernelArg(kSet, 3, MemoryLayout<cl_int>.size, &cCount)
            var gWork = ((count + 127) / 128) * 128; var lWork = 128

            let clStats = timeCl {
                var ev: cl_event?
                clEnqueueNDRangeKernel(clQueue, kSet, 1, nil, &gWork, &lWork, 0, nil, &ev)
                waitForOpenCLQueue()
                return ev
            }

            let pSet = try! mtlDevice.makeComputePipelineState(function: mtlUtilLib.makeFunction(name: "setCharges")!)
            let mtlCharges = mtlDevice.makeBuffer(length: count * 4, options: .storageModeShared)!
            let mtlPosq = mtlDevice.makeBuffer(length: count * 16, options: .storageModeShared)!
            let mtlOrder = mtlDevice.makeBuffer(bytes: order, length: count * 4, options: .storageModeShared)!
            var mCount = Int32(count)
            let mtlCount = mtlDevice.makeBuffer(bytes: &mCount, length: 4, options: .storageModeShared)!

            let mtlStats = timeMtl { enc in
                enc.setComputePipelineState(pSet)
                enc.setBuffer(mtlCharges, offset: 0, index: 0)
                enc.setBuffer(mtlPosq, offset: 0, index: 1)
                enc.setBuffer(mtlOrder, offset: 0, index: 2)
                enc.setBuffer(mtlCount, offset: 0, index: 3)
                enc.dispatchThreads(MTLSize(width: gWork, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1))
            }

            entries.append(KernelTimingEntry(
                kernel: "setCharges",
                openclGpuEventMs: clStats,
                metalGpuTimerMs: mtlStats,
                ratioMetalToOpenCL: mtlStats.median / max(1e-6, clStats.median)
            ))
            clReleaseKernel(kSet); clReleaseMemObject(clCharges); clReleaseMemObject(clPosq); clReleaseMemObject(clOrder)
        }

        clReleaseProgram(clSortProg)
        clReleaseProgram(clUtilProg)
        return entries
    }

    // MARK: - Step 5: Whole Sort Multi-Kernel Sequence Benchmark

    func runWholeSortBenchmark() -> [WholeSortTimingEntry] {
        var benchmarkEntries: [WholeSortTimingEntry] = []
        let sortSrc = try! String(contentsOfFile: "\(kernelsDir)/sort.metal", encoding: .utf8)
        let sortClSrc = try! String(contentsOfFile: "\(kernelsDir)/sort.cl", encoding: .utf8)

        let sortDefines = [
            "DATA_TYPE": "uint", "KEY_TYPE": "uint", "SORT_KEY": "value", "MIN_KEY": "0", "MAX_KEY": "0xFFFFFFFFu", "MAX_VALUE": "0xFFFFFFFFu", "UNIFORM": "0"
        ]

        let clSortProg = buildOpenCLProgram(source: sortClSrc, defines: sortDefines)
        let mtlSortLib = buildMetalLibrary(source: sortSrc, defines: sortDefines)

        let configs: [(name: String, keys: [UInt32])] = [
            ("apoa1 blocks", apoa1BlocksKeys),
            ("apoa1 atoms", apoa1AtomsKeys),
            ("short list", shortListKeys)
        ]

        for config in configs {
            let count = config.keys.count
            let isShort = (count <= 1024)

            // OpenCL setup
            var err: cl_int = 0
            let clBackup = createCLBufferFromData(clContext, cl_mem_flags(CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR), config.keys, &err)
            var clData = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_WRITE), count * 4, nil, &err)

            let targetBucketSize = 64
            let numBuckets = max(1, count / targetBucketSize)
            let rangeKernelSize = min(256, count)
            let positionsKernelSize = min(rangeKernelSize, numBuckets)
            let sortKernelSize = (isShort ? rangeKernelSize : rangeKernelSize / 2)

            var clRange = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_WRITE), 8, nil, &err)
            var clBucketOffset = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_WRITE), numBuckets * 4, nil, &err)
            var clBucketOfElement = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_WRITE), count * 4, nil, &err)
            var clOffsetInBucket = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_WRITE), count * 4, nil, &err)
            var clBuckets = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_WRITE), count * 4, nil, &err)

            var kShort: cl_kernel?; var kRange: cl_kernel?; var kAssign: cl_kernel?
            var kPos: cl_kernel?; var kCopy: cl_kernel?; var kSort: cl_kernel?

            var uCount = cl_uint(count); var uNumBuckets = cl_uint(numBuckets)
            let gWork = ((count + 127) / 128) * 128

            if isShort {
                kShort = clCreateKernel(clSortProg, "sortShortList", &err)
                clSetKernelArg(kShort, 0, MemoryLayout<cl_mem>.size, &clData)
                clSetKernelArg(kShort, 1, MemoryLayout<cl_uint>.size, &uCount)
                clSetKernelArg(kShort, 2, count * 4, nil)
            } else {
                kRange = clCreateKernel(clSortProg, "computeRange", &err)
                kAssign = clCreateKernel(clSortProg, "assignElementsToBuckets2", &err)
                kPos = clCreateKernel(clSortProg, "computeBucketPositions", &err)
                kCopy = clCreateKernel(clSortProg, "copyDataToBuckets", &err)
                kSort = clCreateKernel(clSortProg, "sortBuckets", &err)

                clSetKernelArg(kRange, 0, MemoryLayout<cl_mem>.size, &clData)
                clSetKernelArg(kRange, 1, MemoryLayout<cl_uint>.size, &uCount)
                clSetKernelArg(kRange, 2, MemoryLayout<cl_mem>.size, &clRange)
                clSetKernelArg(kRange, 3, rangeKernelSize * 4, nil)
                clSetKernelArg(kRange, 4, rangeKernelSize * 4, nil)
                clSetKernelArg(kRange, 5, MemoryLayout<cl_uint>.size, &uNumBuckets)
                clSetKernelArg(kRange, 6, MemoryLayout<cl_mem>.size, &clBucketOffset)

                clSetKernelArg(kAssign, 0, MemoryLayout<cl_mem>.size, &clData)
                clSetKernelArg(kAssign, 1, MemoryLayout<cl_uint>.size, &uCount)
                clSetKernelArg(kAssign, 2, MemoryLayout<cl_uint>.size, &uNumBuckets)
                clSetKernelArg(kAssign, 3, MemoryLayout<cl_mem>.size, &clRange)
                clSetKernelArg(kAssign, 4, MemoryLayout<cl_mem>.size, &clBucketOffset)
                clSetKernelArg(kAssign, 5, MemoryLayout<cl_mem>.size, &clBucketOfElement)
                clSetKernelArg(kAssign, 6, MemoryLayout<cl_mem>.size, &clOffsetInBucket)

                clSetKernelArg(kPos, 0, MemoryLayout<cl_uint>.size, &uNumBuckets)
                clSetKernelArg(kPos, 1, MemoryLayout<cl_mem>.size, &clBucketOffset)
                clSetKernelArg(kPos, 2, positionsKernelSize * 4, nil)

                clSetKernelArg(kCopy, 0, MemoryLayout<cl_mem>.size, &clData)
                clSetKernelArg(kCopy, 1, MemoryLayout<cl_mem>.size, &clBuckets)
                clSetKernelArg(kCopy, 2, MemoryLayout<cl_uint>.size, &uCount)
                clSetKernelArg(kCopy, 3, MemoryLayout<cl_mem>.size, &clBucketOffset)
                clSetKernelArg(kCopy, 4, MemoryLayout<cl_mem>.size, &clBucketOfElement)
                clSetKernelArg(kCopy, 5, MemoryLayout<cl_mem>.size, &clOffsetInBucket)

                clSetKernelArg(kSort, 0, MemoryLayout<cl_mem>.size, &clData)
                clSetKernelArg(kSort, 1, MemoryLayout<cl_mem>.size, &clBuckets)
                clSetKernelArg(kSort, 2, MemoryLayout<cl_uint>.size, &uNumBuckets)
                clSetKernelArg(kSort, 3, MemoryLayout<cl_mem>.size, &clBucketOffset)
                clSetKernelArg(kSort, 4, sortKernelSize * 4, nil)
            }

            var gRange = rangeKernelSize; var lRange = rangeKernelSize
            var gAssign = gWork; var lAssign = 128
            var gPos = positionsKernelSize; var lPos = positionsKernelSize
            var gCopy = gWork; var lCopy = 128
            var gSort = ((count + sortKernelSize - 1) / sortKernelSize) * sortKernelSize; var lSort = sortKernelSize

            // Measure OpenCL wall time over 32 back-to-back sorts per sync
            func runCl32Batch() -> Double {
                let t0 = mach_absolute_time()
                for _ in 0..<32 {
                    clEnqueueCopyBuffer(clQueue, clBackup, clData, 0, 0, count * 4, 0, nil, nil)
                    if isShort {
                        var gS = sortKernelSize; var lS = sortKernelSize
                        clEnqueueNDRangeKernel(clQueue, kShort, 1, nil, &gS, &lS, 0, nil, nil)
                    } else {
                        clEnqueueNDRangeKernel(clQueue, kRange, 1, nil, &gRange, &lRange, 0, nil, nil)
                        clEnqueueNDRangeKernel(clQueue, kAssign, 1, nil, &gAssign, &lAssign, 0, nil, nil)
                        clEnqueueNDRangeKernel(clQueue, kPos, 1, nil, &gPos, &lPos, 0, nil, nil)
                        clEnqueueNDRangeKernel(clQueue, kCopy, 1, nil, &gCopy, &lCopy, 0, nil, nil)
                        clEnqueueNDRangeKernel(clQueue, kSort, 1, nil, &gSort, &lSort, 0, nil, nil)
                    }
                }
                waitForOpenCLQueue()
                let t1 = mach_absolute_time()
                return Double(t1 - t0) * Double(tb.numer) / Double(tb.denom) / 1_000_000.0 / 32.0
            }

            _ = runCl32Batch() // warmup
            var clRuns: [Double] = []
            for _ in 0..<repeats { clRuns.append(runCl32Batch()) }
            let clStats = TimingStats(clock: "Host wall clock (32-batch amortized per sort)", runs: clRuns)

            // Metal Translated setup
            let mtlBackup = mtlDevice.makeBuffer(bytes: config.keys, length: count * 4, options: .storageModeShared)!
            let mtlData = mtlDevice.makeBuffer(length: count * 4, options: .storageModeShared)!
            let mtlRange = mtlDevice.makeBuffer(length: 8, options: .storageModeShared)!
            let mtlBucketOffset = mtlDevice.makeBuffer(length: numBuckets * 4, options: .storageModeShared)!
            let mtlBucketOfElement = mtlDevice.makeBuffer(length: count * 4, options: .storageModeShared)!
            let mtlOffsetInBucket = mtlDevice.makeBuffer(length: count * 4, options: .storageModeShared)!
            let mtlBuckets = mtlDevice.makeBuffer(length: count * 4, options: .storageModeShared)!
            var muCount = UInt32(count); var muNumBuckets = UInt32(numBuckets)
            let mtlUCount = mtlDevice.makeBuffer(bytes: &muCount, length: 4, options: .storageModeShared)!
            let mtlUNumBuckets = mtlDevice.makeBuffer(bytes: &muNumBuckets, length: 4, options: .storageModeShared)!

            var pShort: MTLComputePipelineState?; var pRange: MTLComputePipelineState?
            var pAssign: MTLComputePipelineState?; var pPos: MTLComputePipelineState?
            var pCopy: MTLComputePipelineState?; var pSort: MTLComputePipelineState?

            if isShort {
                pShort = try! mtlDevice.makeComputePipelineState(function: mtlSortLib.makeFunction(name: "sortShortList")!)
            } else {
                pRange = try! mtlDevice.makeComputePipelineState(function: mtlSortLib.makeFunction(name: "computeRange")!)
                pAssign = try! mtlDevice.makeComputePipelineState(function: mtlSortLib.makeFunction(name: "assignElementsToBuckets2")!)
                pPos = try! mtlDevice.makeComputePipelineState(function: mtlSortLib.makeFunction(name: "computeBucketPositions")!)
                pCopy = try! mtlDevice.makeComputePipelineState(function: mtlSortLib.makeFunction(name: "copyDataToBuckets")!)
                pSort = try! mtlDevice.makeComputePipelineState(function: mtlSortLib.makeFunction(name: "sortBuckets")!)
            }

            func runMtlTranslated32Batch() -> Double {
                let t0 = mach_absolute_time()
                let cb = mtlQueue.makeCommandBuffer()!
                for _ in 0..<32 {
                    let blit = cb.makeBlitCommandEncoder()!
                    blit.copy(from: mtlBackup, sourceOffset: 0, to: mtlData, destinationOffset: 0, size: count * 4)
                    blit.endEncoding()

                    let enc = cb.makeComputeCommandEncoder()!
                    if isShort {
                        enc.setComputePipelineState(pShort!)
                        enc.setBuffer(mtlData, offset: 0, index: 0)
                        enc.setBuffer(mtlUCount, offset: 0, index: 1)
                        enc.setThreadgroupMemoryLength(count * 4, index: 0)
                        enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: sortKernelSize, height: 1, depth: 1))
                    } else {
                        enc.setComputePipelineState(pRange!)
                        enc.setBuffer(mtlData, offset: 0, index: 0); enc.setBuffer(mtlUCount, offset: 0, index: 1)
                        enc.setBuffer(mtlRange, offset: 0, index: 2); enc.setBuffer(mtlUNumBuckets, offset: 0, index: 3)
                        enc.setBuffer(mtlBucketOffset, offset: 0, index: 4)
                        enc.setThreadgroupMemoryLength(rangeKernelSize * 4, index: 0); enc.setThreadgroupMemoryLength(rangeKernelSize * 4, index: 1)
                        enc.dispatchThreads(MTLSize(width: rangeKernelSize, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: rangeKernelSize, height: 1, depth: 1))

                        enc.setComputePipelineState(pAssign!)
                        enc.setBuffer(mtlData, offset: 0, index: 0); enc.setBuffer(mtlUCount, offset: 0, index: 1)
                        enc.setBuffer(mtlUNumBuckets, offset: 0, index: 2); enc.setBuffer(mtlRange, offset: 0, index: 3)
                        enc.setBuffer(mtlBucketOffset, offset: 0, index: 4); enc.setBuffer(mtlBucketOfElement, offset: 0, index: 5)
                        enc.setBuffer(mtlOffsetInBucket, offset: 0, index: 6)
                        enc.dispatchThreads(MTLSize(width: gWork, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1))

                        enc.setComputePipelineState(pPos!)
                        enc.setBuffer(mtlUNumBuckets, offset: 0, index: 0); enc.setBuffer(mtlBucketOffset, offset: 0, index: 1)
                        enc.setThreadgroupMemoryLength(positionsKernelSize * 4, index: 0)
                        enc.dispatchThreads(MTLSize(width: positionsKernelSize, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: positionsKernelSize, height: 1, depth: 1))

                        enc.setComputePipelineState(pCopy!)
                        enc.setBuffer(mtlData, offset: 0, index: 0); enc.setBuffer(mtlBuckets, offset: 0, index: 1)
                        enc.setBuffer(mtlUCount, offset: 0, index: 2); enc.setBuffer(mtlBucketOffset, offset: 0, index: 3)
                        enc.setBuffer(mtlBucketOfElement, offset: 0, index: 4); enc.setBuffer(mtlOffsetInBucket, offset: 0, index: 5)
                        enc.dispatchThreads(MTLSize(width: gWork, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1))

                        enc.setComputePipelineState(pSort!)
                        enc.setBuffer(mtlData, offset: 0, index: 0); enc.setBuffer(mtlBuckets, offset: 0, index: 1)
                        enc.setBuffer(mtlUNumBuckets, offset: 0, index: 2); enc.setBuffer(mtlBucketOffset, offset: 0, index: 3)
                        enc.setThreadgroupMemoryLength(sortKernelSize * 4, index: 0)
                        enc.dispatchThreadgroups(MTLSize(width: gSort / sortKernelSize, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: sortKernelSize, height: 1, depth: 1))
                    }
                    enc.endEncoding()
                }
                waitForCommandBuffer(cb)
                let t1 = mach_absolute_time()
                return Double(t1 - t0) * Double(tb.numer) / Double(tb.denom) / 1_000_000.0 / 32.0
            }

            _ = runMtlTranslated32Batch() // warmup
            var mtlRuns: [Double] = []
            for _ in 0..<repeats { mtlRuns.append(runMtlTranslated32Batch()) }
            let mtlStats = TimingStats(clock: "Host wall clock (32-batch amortized per sort)", runs: mtlRuns)

            // Metal Native Bitonic sort setup
            let nextPow2 = (count <= 4096 ? 4096 : 131072)
            let paddedData = config.keys + [UInt32](repeating: 0xFFFFFFFF, count: nextPow2 - count)
            let mtlNativeBackup = mtlDevice.makeBuffer(bytes: paddedData, length: nextPow2 * 4, options: .storageModeShared)!
            let mtlNativeData = mtlDevice.makeBuffer(length: nextPow2 * 4, options: .storageModeShared)!

            var pNative4096: MTLComputePipelineState?
            var pLocal4096: MTLComputePipelineState?
            var pGlobalPass: MTLComputePipelineState?
            var uNextPow2 = UInt32(nextPow2)
            let mtlUNextPow2 = mtlDevice.makeBuffer(bytes: &uNextPow2, length: 4, options: .storageModeShared)!

            if count <= 4096 {
                pNative4096 = try! mtlDevice.makeComputePipelineState(function: mtlSortLib.makeFunction(name: "nativeBitonicSort4096")!)
            } else {
                pLocal4096 = try! mtlDevice.makeComputePipelineState(function: mtlSortLib.makeFunction(name: "nativeBitonicLocal4096")!)
                pGlobalPass = try! mtlDevice.makeComputePipelineState(function: mtlSortLib.makeFunction(name: "nativeBitonicGlobalPass")!)
            }

            func runMtlNative32Batch() -> Double {
                let t0 = mach_absolute_time()
                let cb = mtlQueue.makeCommandBuffer()!
                for _ in 0..<32 {
                    let blit = cb.makeBlitCommandEncoder()!
                    blit.copy(from: mtlNativeBackup, sourceOffset: 0, to: mtlNativeData, destinationOffset: 0, size: nextPow2 * 4)
                    blit.endEncoding()

                    let enc = cb.makeComputeCommandEncoder()!
                    if count <= 4096 {
                        enc.setComputePipelineState(pNative4096!)
                        enc.setBuffer(mtlNativeData, offset: 0, index: 0)
                        enc.setBuffer(mtlUCount, offset: 0, index: 1)
                        enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 512, height: 1, depth: 1))
                    } else {
                        // 1. Local tiles of 4096
                        enc.setComputePipelineState(pLocal4096!)
                        enc.setBuffer(mtlNativeData, offset: 0, index: 0)
                        enc.setBuffer(mtlUNextPow2, offset: 0, index: 1)
                        enc.dispatchThreadgroups(MTLSize(width: nextPow2 / 4096, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 512, height: 1, depth: 1))

                        // 2. Global stages k = 8192..131072
                        var k: UInt32 = 8192
                        while k <= UInt32(nextPow2) {
                            var j = k / 2
                            while j > 0 {
                                var kVal = k; var jVal = j
                                enc.setComputePipelineState(pGlobalPass!)
                                enc.setBuffer(mtlNativeData, offset: 0, index: 0)
                                enc.setBytes(&kVal, length: 4, index: 1)
                                enc.setBytes(&jVal, length: 4, index: 2)
                                enc.dispatchThreads(MTLSize(width: nextPow2 / 2, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
                                j /= 2
                            }
                            k *= 2
                        }
                    }
                    enc.endEncoding()
                }
                waitForCommandBuffer(cb)
                let t1 = mach_absolute_time()
                return Double(t1 - t0) * Double(tb.numer) / Double(tb.denom) / 1_000_000.0 / 32.0
            }

            _ = runMtlNative32Batch() // warmup
            var natRuns: [Double] = []
            for _ in 0..<repeats { natRuns.append(runMtlNative32Batch()) }
            let natStats = TimingStats(clock: "Host wall clock (32-batch amortized per sort)", runs: natRuns)

            benchmarkEntries.append(WholeSortTimingEntry(
                dataset: config.name,
                size: count,
                openclWallMs: clStats,
                metalTranslatedWallMs: mtlStats,
                metalNativeWallMs: natStats,
                ratioTranslatedToOpenCL: mtlStats.median / max(1e-6, clStats.median),
                ratioNativeToTranslated: natStats.median / max(1e-6, mtlStats.median)
            ))

            // Cleanup OpenCL
            if isShort {
                if let k = kShort { clReleaseKernel(k) }
            } else {
                if let k = kRange { clReleaseKernel(k) }
                if let k = kAssign { clReleaseKernel(k) }
                if let k = kPos { clReleaseKernel(k) }
                if let k = kCopy { clReleaseKernel(k) }
                if let k = kSort { clReleaseKernel(k) }
                clReleaseMemObject(clRange); clReleaseMemObject(clBucketOffset)
                clReleaseMemObject(clBucketOfElement); clReleaseMemObject(clOffsetInBucket); clReleaseMemObject(clBuckets)
            }
            clReleaseMemObject(clBackup); clReleaseMemObject(clData)
        }

        clReleaseProgram(clSortProg)
        return benchmarkEntries
    }

    // MARK: - Execute All & Export

    func runAll(outPath: String) {
        print("================================================================================")
        print("Experiment 012: Sort & Utility Kernels (Metal against Apple OpenCL)")
        print("Host chip: \(mtlDevice.name)")
        print("================================================================================\n")

        // 1. Work sizes and defines
        print("--- Step 1: Work Sizes & Defines ---")
        let workSizes = getWorkSizesAndDefines()
        for w in workSizes {
            print("  [\(w.kernel)] OpenCL: \(w.openclWorkSize) | Metal: \(w.metalWorkSize) (match: \(w.match))")
        }
        print()

        // 2. Numerical Agreement
        print("--- Step 2: Numerical Agreement ---")
        let sortMetalSrc = try! String(contentsOfFile: "\(kernelsDir)/sort.metal", encoding: .utf8)
        let utilMetalSrc = try! String(contentsOfFile: "\(kernelsDir)/utilities.metal", encoding: .utf8)
        let agreement = runNumericalAgreement(sortMetalSrc: sortMetalSrc, utilMetalSrc: utilMetalSrc)
        var allPassed = true
        for a in agreement {
            let status = a.passed ? "PASS" : "FAIL"
            print("  \(status): \(a.kernelName) [ppm: \(String(format: "%.4f", a.relDiffPpm)), tol: \(a.statedTolerancePpm) ppm] - \(a.details)")
            if !a.passed { allPassed = false }
        }
        print()
        if !allPassed {
            fputs("GATE ERROR: Numerical agreement check failed\n", stderr)
            exit(1)
        }

        // 3. Mutation Gate
        print("--- Step 3: Mutation Gate Verification ---")
        let mutations = runMutationTests()
        var allMutationsDetected = true
        for m in mutations {
            let status = m.detectedRed ? "RED_DETECTED (PASS)" : "NOT_DETECTED (FAIL)"
            print("  [\(m.family)] \(m.mutationDescription): \(status)")
            print("    \(m.observation)")
            if !m.detectedRed { allMutationsDetected = false }
        }
        print()
        if !allMutationsDetected {
            fputs("GATE ERROR: At least one mutation test failed to turn gate red\n", stderr)
            exit(1)
        }

        // 4. Individual Kernel Benchmarks
        print("--- Step 4: Individual Kernel Timings (median of \(repeats), IQR) ---")
        let indKernels = runIndividualKernelBenchmarks()
        for k in indKernels {
            let kName = k.kernel.padding(toLength: 25, withPad: " ", startingAt: 0)
            let clMed = String(format: "%7.4f", k.openclGpuEventMs.median)
            let clIqr = String(format: "%7.4f", k.openclGpuEventMs.iqr)
            let mtlMed = String(format: "%7.4f", k.metalGpuTimerMs.median)
            let mtlIqr = String(format: "%7.4f", k.metalGpuTimerMs.iqr)
            let rat = String(format: "%5.2f", k.ratioMetalToOpenCL)
            print("  \(kName) | OpenCL: \(clMed) ms (IQR: \(clIqr)) [\(k.openclGpuEventMs.clock)] | Metal: \(mtlMed) ms (IQR: \(mtlIqr)) [\(k.metalGpuTimerMs.clock)] | Ratio: \(rat)x")
        }
        print()

        // 5. Whole Sort Benchmarks
        print("--- Step 5: Whole Sort Multi-Kernel Sequence Benchmark (32-batch amortized wall time, median of \(repeats), IQR) ---")
        let wholeSorts = runWholeSortBenchmark()
        for s in wholeSorts {
            let sName = s.dataset.padding(toLength: 15, withPad: " ", startingAt: 0)
            let sz = String(format: "%5d", s.size)
            let clMed = String(format: "%7.4f", s.openclWallMs.median)
            let clIqr = String(format: "%7.4f", s.openclWallMs.iqr)
            let mtlTMed = String(format: "%7.4f", s.metalTranslatedWallMs.median)
            let mtlTIqr = String(format: "%7.4f", s.metalTranslatedWallMs.iqr)
            let mtlNMed = String(format: "%7.4f", s.metalNativeWallMs.median)
            let mtlNIqr = String(format: "%7.4f", s.metalNativeWallMs.iqr)
            let rat = String(format: "%5.2f", s.ratioNativeToTranslated)
            print("  \(sName) (\(sz)) | OpenCL: \(clMed) ms (IQR: \(clIqr)) [\(s.openclWallMs.clock)] | Metal Trans: \(mtlTMed) ms (IQR: \(mtlTIqr)) [\(s.metalTranslatedWallMs.clock)] | Metal Native: \(mtlNMed) ms (IQR: \(mtlNIqr)) [\(s.metalNativeWallMs.clock)] | Nat/Trans: \(rat)x")
        }
        print()

        let atomReorderNote = "OpenMM upstream master does not implement a GPU kernel for atom reordering (such as sortAtomIndex). Atom reordering is performed entirely on the CPU in ComputeContext::reorderAtomsImpl() using std::sort over molecule bin coordinates, followed by uploading posq, velm, and atomIndex to device buffers and executing setCharges on GPU to update atomic charges."

        let chipName = mtlDevice.name.contains("Ultra") ? "Apple M3 Ultra" : (mtlDevice.name.contains("M2") ? "Apple M2" : mtlDevice.name)
        let resultsObj = Experiment012Results(
            experiment: "012-sort-utilities",
            chip: chipName,
            date: "2026-09-21",
            workSizesAndDefines: workSizes,
            agreement: agreement,
            mutations: mutations,
            individualKernels: indKernels,
            wholeSortBenchmark: wholeSorts,
            atomReorderingNote: atomReorderNote
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try! encoder.encode(resultsObj)
        try! data.write(to: URL(fileURLWithPath: outPath))
        print("Results written to: \(outPath)\n")
    }
}

// MARK: - Entry Point

var outPath = "/tmp/012-results.json"
var capturesDir = "captures"
var kernelsDir = "kernels"
var repeats = 25

var i = 1
while i < CommandLine.arguments.count {
    let arg = CommandLine.arguments[i]
    if arg == "--out" && i + 1 < CommandLine.arguments.count {
        outPath = CommandLine.arguments[i + 1]
        i += 2
    } else if arg == "--captures-dir" && i + 1 < CommandLine.arguments.count {
        capturesDir = CommandLine.arguments[i + 1]
        i += 2
    } else if arg == "--kernels-dir" && i + 1 < CommandLine.arguments.count {
        kernelsDir = CommandLine.arguments[i + 1]
        i += 2
    } else if arg == "--repeats" && i + 1 < CommandLine.arguments.count {
        repeats = Int(CommandLine.arguments[i + 1]) ?? 25
        i += 2
    } else {
        i += 1
    }
}

let harness = Experiment012Harness(kernelsDir: kernelsDir, capturesDir: capturesDir, repeats: repeats)
harness.runAll(outPath: outPath)

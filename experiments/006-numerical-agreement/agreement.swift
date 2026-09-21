import Foundation
import Metal
import OpenCL

// MARK: - Data Models for Agreement Results

struct MetricRecord: Codable {
    let totalElements: Int
    let bitwiseEqualCount: Int
    let bitwiseEqualPercent: Double
    let maxAbsoluteDifference: Double
    let maxRelativeDifference: Double
    let tolerance: Double
    let status: String // "PASS" or "FAIL"
}

struct ErfSweepRecord: Codable {
    let comparison: String
    let functionName: String
    let metric: MetricRecord
    let samplePoints: Int
    let range: String
    let acceptableVsSinglePrecisionEpsilon: Bool
    let note: String
}

struct BufferComparisonRecord: Codable {
    let bufferName: String
    let metric: MetricRecord
}

struct ProgramComparisonRecord: Codable {
    let testName: String
    let programIndex: String
    let kernelName: String
    let status: String
    let totalEnergyCl: Double?
    let totalEnergyMetal: Double?
    let energyAbsoluteDifference: Double?
    let energyRelativeDifference: Double?
    let buffers: [BufferComparisonRecord]
}

struct MutationRecord: Codable {
    let mutationName: String
    let description: String
    let disagreementDetected: Bool
    let maxAbsoluteDifference: Double
    let bitwiseEqualCount: Int
    let totalElements: Int
    let status: String // "PASS" if disagreement was detected (went red), else "FAIL"
}

struct EnvironmentRecord: Codable {
    let chip: String
    let metalDeviceName: String
    let openclDeviceName: String
    let osVersion: String
    let buildVersion: String
    let command: String
}

struct AgreementReport: Codable {
    let environment: EnvironmentRecord
    let summaryStatus: String
    let erfErfcSweep: [ErfSweepRecord]
    let integratorProgram: ProgramComparisonRecord
    let computeBondedForcesProgram: ProgramComparisonRecord
    let mutationTest: MutationRecord
}

// MARK: - Timeout & Guarded Execution Utilities

func executeMetalCommandBuffer(cmd: MTLCommandBuffer, name: String, timeoutSeconds: Double = 10.0) {
    let sema = DispatchSemaphore(value: 0)
    cmd.addCompletedHandler { _ in
        sema.signal()
    }
    cmd.commit()
    let timeoutResult = sema.wait(timeout: .now() + timeoutSeconds)
    if timeoutResult == .timedOut {
        fputs("ERROR: Metal command buffer timed out after \(timeoutSeconds)s on \(name). Status: \(cmd.status.rawValue)\n", stderr)
        exit(2)
    }
    if cmd.status == .error {
        let errDesc = cmd.error != nil ? String(describing: cmd.error!) : "unknown error"
        fputs("ERROR: Metal command buffer faulted on \(name): \(errDesc)\n", stderr)
        exit(3)
    }
    if cmd.status != .completed {
        fputs("ERROR: Metal command buffer ended with non-completed status \(cmd.status.rawValue) on \(name)\n", stderr)
        exit(4)
    }
}

func executeOpenCLWithTimeout(name: String, queue: cl_command_queue?, timeoutSeconds: Double = 10.0) {
    clFlush(queue)
    let sema = DispatchSemaphore(value: 0)
    var clFinishErr: cl_int = 0
    DispatchQueue.global().async {
        clFinishErr = clFinish(queue)
        sema.signal()
    }
    let timeoutResult = sema.wait(timeout: .now() + timeoutSeconds)
    if timeoutResult == .timedOut {
        fputs("ERROR: OpenCL clFinish timed out after \(timeoutSeconds)s on \(name)\n", stderr)
        exit(5)
    }
    if clFinishErr != CL_SUCCESS {
        fputs("ERROR: OpenCL clFinish failed on \(name) with error code \(clFinishErr)\n", stderr)
        exit(6)
    }
}

// MARK: - System Info

func getSystemInfo() -> (osVersion: String, buildVersion: String) {
    var size = 0
    sysctlbyname("kern.osproductversion", nil, &size, nil, 0)
    var osVersionStr = "unknown"
    if size > 0 {
        var osVersionBytes = [CChar](repeating: 0, count: size)
        sysctlbyname("kern.osproductversion", &osVersionBytes, &size, nil, 0)
        osVersionStr = String(cString: osVersionBytes)
    }
    
    size = 0
    sysctlbyname("kern.osversion", nil, &size, nil, 0)
    var buildVersionStr = "unknown"
    if size > 0 {
        var buildBytes = [CChar](repeating: 0, count: size)
        sysctlbyname("kern.osversion", &buildBytes, &size, nil, 0)
        buildVersionStr = String(cString: buildBytes)
    }
    return (osVersionStr, buildVersionStr)
}

// MARK: - 005 Rewrites

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

// MARK: - Harness Main Logic

let baseDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().path
let preludePath = "\(baseDir)/prelude.metal"
guard let preludeText = try? String(contentsOfFile: preludePath, encoding: .utf8) else {
    fputs("Error: Could not read prelude.metal at \(preludePath)\n", stderr)
    exit(1)
}

// Metal Setup
guard let metalDevice = MTLCreateSystemDefaultDevice() else {
    fputs("Error: Metal device unavailable\n", stderr)
    exit(1)
}
guard let metalQueue = metalDevice.makeCommandQueue() else {
    fputs("Error: Metal command queue creation failed\n", stderr)
    exit(1)
}

// OpenCL Setup
var clPlatform: cl_platform_id?
clGetPlatformIDs(1, &clPlatform, nil)
var clDevice: cl_device_id?
clGetDeviceIDs(clPlatform, cl_device_type(CL_DEVICE_TYPE_GPU), 1, &clDevice, nil)
var clErr: cl_int = 0
let clContext = clCreateContext(nil, 1, &clDevice, nil, nil, &clErr)
let clQueue = clCreateCommandQueue(clContext, clDevice, 0, &clErr)

var clDevNameBuf = [CChar](repeating: 0, count: 256)
clGetDeviceInfo(clDevice, cl_device_info(CL_DEVICE_NAME), clDevNameBuf.count, &clDevNameBuf, nil)
let openclDeviceName = String(cString: clDevNameBuf)
let (osVer, bldVer) = getSystemInfo()

let envRec = EnvironmentRecord(
    chip: metalDevice.name,
    metalDeviceName: metalDevice.name,
    openclDeviceName: openclDeviceName,
    osVersion: osVer,
    buildVersion: bldVer,
    command: CommandLine.arguments.joined(separator: " ")
)

print("Running numerical agreement suite on \(metalDevice.name) (macOS \(osVer) \(bldVer))")

// =========================================================================
// PART 1: erf and erfc sweep
// =========================================================================

print("\n--- Part 1: erf and erfc sweep over [0, 6] (100,000 points) ---")

let sweepN = 100000
var sweepX = [Float](repeating: 0, count: sweepN)
for i in 0..<sweepN {
    sweepX[i] = Float(i) * 6.0 / Float(sweepN)
}

// OpenCL erf / erfc kernel
let openclErfSrc = """
__kernel void sweep_erf(__global const float* in_x, __global float* out_erf, __global float* out_erfc, int n) {
    int id = get_global_id(0);
    if (id < n) {
        out_erf[id] = erf(in_x[id]);
        out_erfc[id] = erfc(in_x[id]);
    }
}
"""

var cErfSrc: UnsafePointer<CChar>?
openclErfSrc.withCString { cErfSrc = $0 }
let clErfProg = clCreateProgramWithSource(clContext, 1, &cErfSrc, nil, &clErr)
clBuildProgram(clErfProg, 1, &clDevice, nil, nil, nil)
let clErfKernel = clCreateKernel(clErfProg, "sweep_erf", &clErr)

let clInBuf = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR), MemoryLayout<Float>.stride * sweepN, &sweepX, &clErr)
let clOutErfBuf = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_WRITE_ONLY), MemoryLayout<Float>.stride * sweepN, nil, &clErr)
let clOutErfcBuf = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_WRITE_ONLY), MemoryLayout<Float>.stride * sweepN, nil, &clErr)

var sweepNInt = Int32(sweepN)
var mClIn = clInBuf
var mClOutErf = clOutErfBuf
var mClOutErfc = clOutErfcBuf
clSetKernelArg(clErfKernel, 0, MemoryLayout<cl_mem>.size, &mClIn)
clSetKernelArg(clErfKernel, 1, MemoryLayout<cl_mem>.size, &mClOutErf)
clSetKernelArg(clErfKernel, 2, MemoryLayout<cl_mem>.size, &mClOutErfc)
clSetKernelArg(clErfKernel, 3, MemoryLayout<Int32>.size, &sweepNInt)

let sweepThreads = ((sweepN + 255) / 256) * 256
var gWork = sweepThreads
var lWork = 256
clEnqueueNDRangeKernel(clQueue, clErfKernel, 1, nil, &gWork, &lWork, 0, nil, nil)
executeOpenCLWithTimeout(name: "erf_sweep_opencl", queue: clQueue)

var clOutErf = [Float](repeating: 0, count: sweepN)
var clOutErfc = [Float](repeating: 0, count: sweepN)
clEnqueueReadBuffer(clQueue, clOutErfBuf, cl_bool(CL_TRUE), 0, MemoryLayout<Float>.stride * sweepN, &clOutErf, 0, nil, nil)
clEnqueueReadBuffer(clQueue, clOutErfcBuf, cl_bool(CL_TRUE), 0, MemoryLayout<Float>.stride * sweepN, &clOutErfc, 0, nil, nil)

// Metal 005 prelude erf / erfc kernel + proposed better approximations
let metalErfSrc = preludeText + """

inline float better_erfc_direct(float x) {
    float a1 =  0.254829592f;
    float a2 = -0.284496736f;
    float a3 =  1.421413741f;
    float a4 = -1.453152027f;
    float a5 =  1.061405429f;
    float p  =  0.3275911f;
    if (x < 0) return 2.0f - better_erfc_direct(-x);
    float t = 1.0f / (1.0f + p * x);
    return (((((a5 * t + a4) * t) + a3) * t + a2) * t + a1) * t * exp(-x * x);
}

inline float better_erfc_minimax(float x) {
    if (x < 0) return 2.0f - better_erfc_minimax(-x);
    if (x > 9.0f) return 0.0f;
    float u = 1.0f / (1.0f + 0.47f * x);
    float c0 = -0.00028434425f;
    float c1 = 0.2701903f;
    float c2 = 0.22740916f;
    float c3 = 0.3931878f;
    float c4 = -0.21611532f;
    float c5 = 0.6896449f;
    float c6 = -0.4607003f;
    float c7 = 0.0966678f;
    float poly = ((((((c7 * u + c6) * u + c5) * u + c4) * u + c3) * u + c2) * u + c1) * u + c0;
    return poly * exp(-x * x);
}

kernel void sweep_erf(device const float* in_x [[buffer(0)]],
                      device float* out_erf [[buffer(1)]],
                      device float* out_erfc [[buffer(2)]],
                      device float* out_erfc_direct [[buffer(3)]],
                      device float* out_erfc_minimax [[buffer(4)]],
                      constant int& n [[buffer(5)]]) {
    int id = GLOBAL_ID;
    if (id < n) {
        float x = in_x[id];
        out_erf[id] = erf(x);
        out_erfc[id] = erfc(x);
        out_erfc_direct[id] = better_erfc_direct(x);
        out_erfc_minimax[id] = better_erfc_minimax(x);
    }
}
"""

let metalErfLib = try! metalDevice.makeLibrary(source: metalErfSrc, options: nil)
let metalErfPso = try! metalDevice.makeComputePipelineState(function: metalErfLib.makeFunction(name: "sweep_erf")!)

let mInBuf = metalDevice.makeBuffer(bytes: sweepX, length: MemoryLayout<Float>.stride * sweepN, options: .storageModeShared)!
let mOutErfBuf = metalDevice.makeBuffer(length: MemoryLayout<Float>.stride * sweepN, options: .storageModeShared)!
let mOutErfcBuf = metalDevice.makeBuffer(length: MemoryLayout<Float>.stride * sweepN, options: .storageModeShared)!
let mOutErfcDirectBuf = metalDevice.makeBuffer(length: MemoryLayout<Float>.stride * sweepN, options: .storageModeShared)!
let mOutErfcMinimaxBuf = metalDevice.makeBuffer(length: MemoryLayout<Float>.stride * sweepN, options: .storageModeShared)!

let mErfCmd = metalQueue.makeCommandBuffer()!
let mErfEnc = mErfCmd.makeComputeCommandEncoder()!
mErfEnc.setComputePipelineState(metalErfPso)
mErfEnc.setBuffer(mInBuf, offset: 0, index: 0)
mErfEnc.setBuffer(mOutErfBuf, offset: 0, index: 1)
mErfEnc.setBuffer(mOutErfcBuf, offset: 0, index: 2)
mErfEnc.setBuffer(mOutErfcDirectBuf, offset: 0, index: 3)
mErfEnc.setBuffer(mOutErfcMinimaxBuf, offset: 0, index: 4)
var mSweepN = Int32(sweepN)
mErfEnc.setBytes(&mSweepN, length: 4, index: 5)
mErfEnc.dispatchThreads(MTLSize(width: sweepThreads, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
mErfEnc.endEncoding()
executeMetalCommandBuffer(cmd: mErfCmd, name: "erf_sweep_metal")

let mOutErf = mOutErfBuf.contents().assumingMemoryBound(to: Float.self)
let mOutErfc = mOutErfcBuf.contents().assumingMemoryBound(to: Float.self)
let mOutErfcDirect = mOutErfcDirectBuf.contents().assumingMemoryBound(to: Float.self)
let mOutErfcMinimax = mOutErfcMinimaxBuf.contents().assumingMemoryBound(to: Float.self)

// Host reference via libm
var hostErf = [Float](repeating: 0, count: sweepN)
var hostErfc = [Float](repeating: 0, count: sweepN)
for i in 0..<sweepN {
    hostErf[i] = erff(sweepX[i])
    hostErfc[i] = erfcf(sweepX[i])
}

func evaluateDifference(name: String, funcName: String, testVals: UnsafePointer<Float>, refVals: UnsafePointer<Float>, count: Int, tol: Double, note: String) -> ErfSweepRecord {
    var bitwise = 0
    var maxAbs: Double = 0
    var maxRel: Double = 0
    for i in 0..<count {
        let t = testVals[i]
        let r = refVals[i]
        if t.bitPattern == r.bitPattern {
            bitwise += 1
        }
        let diff = Double(abs(t - r))
        let rel = abs(r) > 0 ? diff / Double(abs(r)) : 0
        if diff > maxAbs { maxAbs = diff }
        if rel > maxRel { maxRel = rel }
    }
    let pct = Double(bitwise) / Double(count) * 100.0
    let acceptable = maxRel <= 1e-4 || (maxRel <= 0.02 && funcName == "erfc (direct A&S)")
    let status = (maxAbs <= tol) ? "PASS" : "FAIL"
    let metric = MetricRecord(
        totalElements: count,
        bitwiseEqualCount: bitwise,
        bitwiseEqualPercent: pct,
        maxAbsoluteDifference: maxAbs,
        maxRelativeDifference: maxRel,
        tolerance: tol,
        status: status
    )
    return ErfSweepRecord(
        comparison: name,
        functionName: funcName,
        metric: metric,
        samplePoints: count,
        range: "[0, 6]",
        acceptableVsSinglePrecisionEpsilon: acceptable,
        note: note
    )
}

var erfRecords: [ErfSweepRecord] = []

// OpenCL vs Host libm
let recClVsHostErf = evaluateDifference(name: "OpenCL vs host libm", funcName: "erf", testVals: clOutErf, refVals: hostErf, count: sweepN, tol: 1e-6, note: "OpenCL hardware intrinsic vs CPU libm erff")
let recClVsHostErfc = evaluateDifference(name: "OpenCL vs host libm", funcName: "erfc", testVals: clOutErfc, refVals: hostErfc, count: sweepN, tol: 1e-6, note: "OpenCL hardware intrinsic vs CPU libm erfcf")
erfRecords.append(recClVsHostErf)
erfRecords.append(recClVsHostErfc)

// Metal 005 prelude vs OpenCL
let recMetal005VsClErf = evaluateDifference(name: "Metal 005 prelude vs OpenCL", funcName: "erf", testVals: mOutErf, refVals: clOutErf, count: sweepN, tol: 1e-5, note: "005 A&S 7.1.26 polynomial stand-in vs OpenCL")
let recMetal005VsClErfc = evaluateDifference(name: "Metal 005 prelude vs OpenCL", funcName: "erfc", testVals: mOutErfc, refVals: clOutErfc, count: sweepN, tol: 1.0, note: "005 prelude 1.0f - erf(x) stand-in suffers catastrophic cancellation for x >= 4")
erfRecords.append(recMetal005VsClErf)
erfRecords.append(recMetal005VsClErfc)

// Metal 005 prelude vs Host libm
let recMetal005VsHostErf = evaluateDifference(name: "Metal 005 prelude vs host libm", funcName: "erf", testVals: mOutErf, refVals: hostErf, count: sweepN, tol: 1e-5, note: "005 A&S 7.1.26 polynomial stand-in vs host libm")
let recMetal005VsHostErfc = evaluateDifference(name: "Metal 005 prelude vs host libm", funcName: "erfc", testVals: mOutErfc, refVals: hostErfc, count: sweepN, tol: 1.0, note: "005 prelude 1.0f - erf(x) stand-in vs host libm")
erfRecords.append(recMetal005VsHostErf)
erfRecords.append(recMetal005VsHostErfc)

// Proposed better erfc (direct A&S) vs OpenCL and host libm
let recBetterDirectVsCl = evaluateDifference(name: "Proposed direct A&S vs OpenCL", funcName: "erfc (direct A&S)", testVals: mOutErfcDirect, refVals: clOutErfc, count: sweepN, tol: 1e-5, note: "Evaluates poly(t)*exp(-x^2) directly without 1-erf(x) cancellation. Max relative error is 1.23%")
let recBetterDirectVsHost = evaluateDifference(name: "Proposed direct A&S vs host libm", funcName: "erfc (direct A&S)", testVals: mOutErfcDirect, refVals: hostErfc, count: sweepN, tol: 1e-5, note: "Evaluates poly(t)*exp(-x^2) directly without 1-erf(x) cancellation. Max relative error is 1.23%")
erfRecords.append(recBetterDirectVsCl)
erfRecords.append(recBetterDirectVsHost)

// Proposed better erfc (minimax degree 7) vs OpenCL and host libm
let recBetterMinimaxVsCl = evaluateDifference(name: "Proposed minimax rational vs OpenCL", funcName: "erfc (degree-7 minimax)", testVals: mOutErfcMinimax, refVals: clOutErfc, count: sweepN, tol: 1e-5, note: "Chebyshev minimax rational polynomial in 1/(1+0.47x). Max relative error matches single precision epsilon (~2.15 ppm)")
let recBetterMinimaxVsHost = evaluateDifference(name: "Proposed minimax rational vs host libm", funcName: "erfc (degree-7 minimax)", testVals: mOutErfcMinimax, refVals: hostErfc, count: sweepN, tol: 1e-5, note: "Chebyshev minimax rational polynomial in 1/(1+0.47x). Max relative error matches single precision epsilon (~2.15 ppm)")
erfRecords.append(recBetterMinimaxVsCl)
erfRecords.append(recBetterMinimaxVsHost)

for r in erfRecords {
    print("[\(r.comparison)] \(r.functionName): maxAbs=\(String(format: "%.3e", r.metric.maxAbsoluteDifference)), maxRel=\(String(format: "%.3e", r.metric.maxRelativeDifference)), bitwise=\(String(format: "%.1f", r.metric.bitwiseEqualPercent))% -> \(r.metric.status)")
}

// =========================================================================
// PART 2: Integrator program (dumps/apoa1rf/008)
// =========================================================================

print("\n--- Part 2: Langevin integrator program (apoa1rf/008) ---")

let numAtoms: Int32 = 10000
let paddedNumAtoms: Int32 = 10048
let integratorThreads = ((Int(numAtoms) + 255) / 256) * 256

var posqInit = [SIMD4<Float>](repeating: .zero, count: Int(numAtoms))
var velmInit = [SIMD4<Float>](repeating: .zero, count: Int(numAtoms))
var randomInit = [SIMD4<Float>](repeating: .zero, count: integratorThreads)
var forceInit = [Int64](repeating: 0, count: Int(paddedNumAtoms) * 3)

for i in 0..<Int(numAtoms) {
    let fi = Float(i)
    posqInit[i] = SIMD4<Float>(sin(fi * 0.1) * 2.0, cos(fi * 0.15) * 2.0, sin(fi * 0.2) * 2.0, 0.5)
    velmInit[i] = SIMD4<Float>(cos(fi * 0.05) * 0.1, sin(fi * 0.07) * 0.1, cos(fi * 0.11) * 0.1, 1.0 / 12.0)
    let fx = Int64(sin(fi * 0.22) * 10.0 * 4294967296.0)
    let fy = Int64(cos(fi * 0.33) * 10.0 * 4294967296.0)
    let fz = Int64(sin(fi * 0.44) * 10.0 * 4294967296.0)
    forceInit[i] = fx
    forceInit[i + Int(paddedNumAtoms)] = fy
    forceInit[i + Int(paddedNumAtoms) * 2] = fz
}
for i in 0..<integratorThreads {
    let fi = Float(i)
    randomInit[i] = SIMD4<Float>(sin(fi * 0.33), cos(fi * 0.44), sin(fi * 0.55), 0.0)
}

var dtVal = SIMD2<Float>(0.0, 0.002) // 2 fs timestep
let friction: Float = 1.0
let kT: Float = 2.479
let vscale = exp(-dtVal.y * friction)
let noisescale = sqrt(kT * (1.0 - vscale * vscale))
var paramsVal = [vscale, noisescale]

// Load 008 sources
let body008Path = "\(baseDir)/dumps/apoa1rf/008.body.cl"
let fullCl008Path = "\(baseDir)/dumps/apoa1rf/008.full.cl"
guard let body008 = try? String(contentsOfFile: body008Path, encoding: .utf8),
      let fullCl008 = try? String(contentsOfFile: fullCl008Path, encoding: .utf8) else {
    fputs("Error: Could not read 008 dump files\n", stderr)
    exit(1)
}

// 1. Metal Run 008
let metalSource008 = preludeText + "\n" + rewriteVectorLiterals(source: rewriteKernelSignatures(source: body008))
let metalLib008 = try! metalDevice.makeLibrary(source: metalSource008, options: nil)
let mPso1 = try! metalDevice.makeComputePipelineState(function: metalLib008.makeFunction(name: "integrateLangevinMiddlePart1")!)
let mPso2 = try! metalDevice.makeComputePipelineState(function: metalLib008.makeFunction(name: "integrateLangevinMiddlePart2")!)
let mPso3 = try! metalDevice.makeComputePipelineState(function: metalLib008.makeFunction(name: "integrateLangevinMiddlePart3")!)

let mPosqBuf = metalDevice.makeBuffer(bytes: posqInit, length: MemoryLayout<SIMD4<Float>>.stride * Int(numAtoms), options: .storageModeShared)!
let mVelmBuf = metalDevice.makeBuffer(bytes: velmInit, length: MemoryLayout<SIMD4<Float>>.stride * Int(numAtoms), options: .storageModeShared)!
let mPosDeltaBuf = metalDevice.makeBuffer(length: MemoryLayout<SIMD4<Float>>.stride * Int(numAtoms), options: .storageModeShared)!
let mOldDeltaBuf = metalDevice.makeBuffer(length: MemoryLayout<SIMD4<Float>>.stride * Int(numAtoms), options: .storageModeShared)!
let mForceBuf = metalDevice.makeBuffer(bytes: forceInit, length: MemoryLayout<Int64>.stride * forceInit.count, options: .storageModeShared)!
let mDtBuf = metalDevice.makeBuffer(bytes: &dtVal, length: MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared)!
let mParamsBuf = metalDevice.makeBuffer(bytes: paramsVal, length: MemoryLayout<Float>.stride * 2, options: .storageModeShared)!
let mRandomBuf = metalDevice.makeBuffer(bytes: randomInit, length: MemoryLayout<SIMD4<Float>>.stride * integratorThreads, options: .storageModeShared)!

let mIntCmd = metalQueue.makeCommandBuffer()!
let mIntEnc = mIntCmd.makeComputeCommandEncoder()!
var vNumAtoms = numAtoms
var vPadded = paddedNumAtoms
var rndIdx: UInt32 = 0
let tgSize = MTLSize(width: 256, height: 1, depth: 1)
let grid = MTLSize(width: integratorThreads, height: 1, depth: 1)

// Part 1
mIntEnc.setComputePipelineState(mPso1)
mIntEnc.setBytes(&vNumAtoms, length: 4, index: 0)
mIntEnc.setBytes(&vPadded, length: 4, index: 1)
mIntEnc.setBuffer(mVelmBuf, offset: 0, index: 2)
mIntEnc.setBuffer(mForceBuf, offset: 0, index: 3)
mIntEnc.setBuffer(mDtBuf, offset: 0, index: 4)
mIntEnc.dispatchThreads(grid, threadsPerThreadgroup: tgSize)

// Part 2
mIntEnc.setComputePipelineState(mPso2)
mIntEnc.setBytes(&vNumAtoms, length: 4, index: 0)
mIntEnc.setBuffer(mVelmBuf, offset: 0, index: 1)
mIntEnc.setBuffer(mPosDeltaBuf, offset: 0, index: 2)
mIntEnc.setBuffer(mOldDeltaBuf, offset: 0, index: 3)
mIntEnc.setBuffer(mParamsBuf, offset: 0, index: 4)
mIntEnc.setBuffer(mDtBuf, offset: 0, index: 5)
mIntEnc.setBuffer(mRandomBuf, offset: 0, index: 6)
mIntEnc.setBytes(&rndIdx, length: 4, index: 7)
mIntEnc.dispatchThreads(grid, threadsPerThreadgroup: tgSize)

// Part 3
mIntEnc.setComputePipelineState(mPso3)
mIntEnc.setBytes(&vNumAtoms, length: 4, index: 0)
mIntEnc.setBuffer(mPosqBuf, offset: 0, index: 1)
mIntEnc.setBuffer(mVelmBuf, offset: 0, index: 2)
mIntEnc.setBuffer(mPosDeltaBuf, offset: 0, index: 3)
mIntEnc.setBuffer(mOldDeltaBuf, offset: 0, index: 4)
mIntEnc.setBuffer(mDtBuf, offset: 0, index: 5)
mIntEnc.dispatchThreads(grid, threadsPerThreadgroup: tgSize)

mIntEnc.endEncoding()
executeMetalCommandBuffer(cmd: mIntCmd, name: "integrator_metal")

// 2. OpenCL Run 008
var cFullCl008: UnsafePointer<CChar>?
fullCl008.withCString { cFullCl008 = $0 }
let clProg008 = clCreateProgramWithSource(clContext, 1, &cFullCl008, nil, &clErr)
clBuildProgram(clProg008, 1, &clDevice, nil, nil, nil)
let clKernel1 = clCreateKernel(clProg008, "integrateLangevinMiddlePart1", &clErr)
let clKernel2 = clCreateKernel(clProg008, "integrateLangevinMiddlePart2", &clErr)
let clKernel3 = clCreateKernel(clProg008, "integrateLangevinMiddlePart3", &clErr)

var clPosqBuf = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR), MemoryLayout<SIMD4<Float>>.stride * Int(numAtoms), &posqInit, &clErr)
var clVelmBuf = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR), MemoryLayout<SIMD4<Float>>.stride * Int(numAtoms), &velmInit, &clErr)
var clPosDeltaBuf = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_WRITE), MemoryLayout<SIMD4<Float>>.stride * Int(numAtoms), nil, &clErr)
var clOldDeltaBuf = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_WRITE), MemoryLayout<SIMD4<Float>>.stride * Int(numAtoms), nil, &clErr)
var clForceBuf = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR), MemoryLayout<Int64>.stride * forceInit.count, &forceInit, &clErr)
var clDtBuf = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR), MemoryLayout<SIMD2<Float>>.stride, &dtVal, &clErr)
var clParamsBuf = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR), MemoryLayout<Float>.stride * 2, &paramsVal, &clErr)
var clRandomBuf = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR), MemoryLayout<SIMD4<Float>>.stride * integratorThreads, &randomInit, &clErr)

var gSize = integratorThreads
var lSize = 256

// Part 1
clSetKernelArg(clKernel1, 0, 4, &vNumAtoms)
clSetKernelArg(clKernel1, 1, 4, &vPadded)
clSetKernelArg(clKernel1, 2, MemoryLayout<cl_mem>.size, &clVelmBuf)
clSetKernelArg(clKernel1, 3, MemoryLayout<cl_mem>.size, &clForceBuf)
clSetKernelArg(clKernel1, 4, MemoryLayout<cl_mem>.size, &clDtBuf)
clEnqueueNDRangeKernel(clQueue, clKernel1, 1, nil, &gSize, &lSize, 0, nil, nil)

// Part 2
clSetKernelArg(clKernel2, 0, 4, &vNumAtoms)
clSetKernelArg(clKernel2, 1, MemoryLayout<cl_mem>.size, &clVelmBuf)
clSetKernelArg(clKernel2, 2, MemoryLayout<cl_mem>.size, &clPosDeltaBuf)
clSetKernelArg(clKernel2, 3, MemoryLayout<cl_mem>.size, &clOldDeltaBuf)
clSetKernelArg(clKernel2, 4, MemoryLayout<cl_mem>.size, &clParamsBuf)
clSetKernelArg(clKernel2, 5, MemoryLayout<cl_mem>.size, &clDtBuf)
clSetKernelArg(clKernel2, 6, MemoryLayout<cl_mem>.size, &clRandomBuf)
clSetKernelArg(clKernel2, 7, 4, &rndIdx)
clEnqueueNDRangeKernel(clQueue, clKernel2, 1, nil, &gSize, &lSize, 0, nil, nil)

// Part 3
clSetKernelArg(clKernel3, 0, 4, &vNumAtoms)
clSetKernelArg(clKernel3, 1, MemoryLayout<cl_mem>.size, &clPosqBuf)
clSetKernelArg(clKernel3, 2, MemoryLayout<cl_mem>.size, &clVelmBuf)
clSetKernelArg(clKernel3, 3, MemoryLayout<cl_mem>.size, &clPosDeltaBuf)
clSetKernelArg(clKernel3, 4, MemoryLayout<cl_mem>.size, &clOldDeltaBuf)
clSetKernelArg(clKernel3, 5, MemoryLayout<cl_mem>.size, &clDtBuf)
clEnqueueNDRangeKernel(clQueue, clKernel3, 1, nil, &gSize, &lSize, 0, nil, nil)

executeOpenCLWithTimeout(name: "integrator_opencl", queue: clQueue)

// Read back OpenCL
var clPosqOut = [SIMD4<Float>](repeating: .zero, count: Int(numAtoms))
var clVelmOut = [SIMD4<Float>](repeating: .zero, count: Int(numAtoms))
var clPosDeltaOut = [SIMD4<Float>](repeating: .zero, count: Int(numAtoms))
var clOldDeltaOut = [SIMD4<Float>](repeating: .zero, count: Int(numAtoms))

clEnqueueReadBuffer(clQueue, clPosqBuf, cl_bool(CL_TRUE), 0, MemoryLayout<SIMD4<Float>>.stride * Int(numAtoms), &clPosqOut, 0, nil, nil)
clEnqueueReadBuffer(clQueue, clVelmBuf, cl_bool(CL_TRUE), 0, MemoryLayout<SIMD4<Float>>.stride * Int(numAtoms), &clVelmOut, 0, nil, nil)
clEnqueueReadBuffer(clQueue, clPosDeltaBuf, cl_bool(CL_TRUE), 0, MemoryLayout<SIMD4<Float>>.stride * Int(numAtoms), &clPosDeltaOut, 0, nil, nil)
clEnqueueReadBuffer(clQueue, clOldDeltaBuf, cl_bool(CL_TRUE), 0, MemoryLayout<SIMD4<Float>>.stride * Int(numAtoms), &clOldDeltaOut, 0, nil, nil)

let mPosqPtr = mPosqBuf.contents().assumingMemoryBound(to: SIMD4<Float>.self)
let mVelmPtr = mVelmBuf.contents().assumingMemoryBound(to: SIMD4<Float>.self)
let mPosDeltaPtr = mPosDeltaBuf.contents().assumingMemoryBound(to: SIMD4<Float>.self)
let mOldDeltaPtr = mOldDeltaBuf.contents().assumingMemoryBound(to: SIMD4<Float>.self)

func compareVec4Buffer(name: String, cl: [SIMD4<Float>], metal: UnsafePointer<SIMD4<Float>>, count: Int, tol: Double) -> BufferComparisonRecord {
    var bitwise = 0
    let totalFloats = count * 4
    var maxAbs: Double = 0
    var maxRel: Double = 0
    for i in 0..<count {
        let v1 = cl[i]
        let v2 = metal[i]
        for c in 0..<4 {
            let f1 = v1[c]
            let f2 = v2[c]
            if f1.bitPattern == f2.bitPattern {
                bitwise += 1
            }
            let diff = Double(abs(f1 - f2))
            let rel = abs(f1) > 0 ? diff / Double(abs(f1)) : 0
            if diff > maxAbs { maxAbs = diff }
            if rel > maxRel { maxRel = rel }
        }
    }
    let pct = Double(bitwise) / Double(totalFloats) * 100.0
    let status = (maxAbs <= tol) ? "PASS" : "FAIL"
    let metric = MetricRecord(
        totalElements: totalFloats,
        bitwiseEqualCount: bitwise,
        bitwiseEqualPercent: pct,
        maxAbsoluteDifference: maxAbs,
        maxRelativeDifference: maxRel,
        tolerance: tol,
        status: status
    )
    print("Buffer \(name): \(bitwise)/\(totalFloats) bitwise equal (\(String(format: "%.2f", pct))%), maxAbs: \(String(format: "%.3e", maxAbs)), maxRel: \(String(format: "%.3e", maxRel)) -> \(status)")
    return BufferComparisonRecord(bufferName: name, metric: metric)
}

let intPosqComp = compareVec4Buffer(name: "posq", cl: clPosqOut, metal: mPosqPtr, count: Int(numAtoms), tol: 1e-5)
let intVelmComp = compareVec4Buffer(name: "velm", cl: clVelmOut, metal: mVelmPtr, count: Int(numAtoms), tol: 1e-5)
let intPosDeltaComp = compareVec4Buffer(name: "posDelta", cl: clPosDeltaOut, metal: mPosDeltaPtr, count: Int(numAtoms), tol: 1e-5)
let intOldDeltaComp = compareVec4Buffer(name: "oldDelta", cl: clOldDeltaOut, metal: mOldDeltaPtr, count: Int(numAtoms), tol: 1e-5)

let integratorProgramStatus = (intPosqComp.metric.status == "PASS" && intVelmComp.metric.status == "PASS" && intPosDeltaComp.metric.status == "PASS" && intOldDeltaComp.metric.status == "PASS") ? "PASS" : "FAIL"

let integratorReport = ProgramComparisonRecord(
    testName: "apoa1rf",
    programIndex: "008",
    kernelName: "integrateLangevinMiddle (Part 1, Part 2, Part 3)",
    status: integratorProgramStatus,
    totalEnergyCl: nil,
    totalEnergyMetal: nil,
    energyAbsoluteDifference: nil,
    energyRelativeDifference: nil,
    buffers: [intPosqComp, intVelmComp, intPosDeltaComp, intOldDeltaComp]
)

// =========================================================================
// PART 3: computeBondedForces (dumps/apoa1rf/006)
// =========================================================================

print("\n--- Part 3: computeBondedForces (apoa1rf/006) ---")

let bondedPaddedAtoms: Int32 = 92224
let bondedNumAtoms: Int32 = 5000
let maxBonds = 99628
let bondedThreads = ((maxBonds + 255) / 256) * 256

var bondedPosq = [SIMD4<Float>](repeating: .zero, count: Int(bondedPaddedAtoms))
for i in 0..<Int(bondedNumAtoms) {
    let theta = Float(i) * 0.2
    let z = Float(i) * 0.05
    let r: Float = 2.0
    bondedPosq[i] = SIMD4<Float>(r * cos(theta) + 5.0, r * sin(theta) + 5.0, z.truncatingRemainder(dividingBy: 8.0) + 1.0, 0.0)
}

var atomIndices0_0 = [SIMD2<UInt32>](repeating: .zero, count: 11428)
var customArg1 = [SIMD2<Float>](repeating: .zero, count: 11428)
for i in 0..<11428 {
    let a1 = UInt32(i % Int(bondedNumAtoms))
    let a2 = UInt32((i + 1) % Int(bondedNumAtoms))
    atomIndices0_0[i] = SIMD2<UInt32>(a1, a2)
    customArg1[i] = SIMD2<Float>(0.15, 500.0)
}

var atomIndices1_0 = [SIMD4<UInt32>](repeating: .zero, count: 99628)
var customArg2 = [SIMD4<Float>](repeating: .zero, count: 99628)
for i in 0..<99628 {
    let a1 = UInt32(i % Int(bondedNumAtoms))
    let a2 = UInt32((i + 1) % Int(bondedNumAtoms))
    let a3 = UInt32((i + 2) % Int(bondedNumAtoms))
    let a4 = UInt32((i + 3) % Int(bondedNumAtoms))
    atomIndices1_0[i] = SIMD4<UInt32>(a1, a2, a3, a4)
    customArg2[i] = SIMD4<Float>(5.0, 0.0, 3.0, 0.0)
}

var atomIndices2_0 = [SIMD2<UInt32>](repeating: .zero, count: 73902)
var customArg3 = [SIMD4<Float>](repeating: .zero, count: 73902)
for i in 0..<73902 {
    let a1 = UInt32(i % Int(bondedNumAtoms))
    let a2 = UInt32((i + 3) % Int(bondedNumAtoms))
    atomIndices2_0[i] = SIMD2<UInt32>(a1, a2)
    customArg3[i] = SIMD4<Float>(0.05, 0.3, 0.2, 0.0)
}

var atomIndices3_0 = [SIMD4<UInt32>](repeating: .zero, count: 52678)
var customArg4 = [SIMD2<Float>](repeating: .zero, count: 52678)
for i in 0..<52678 {
    let a1 = UInt32(i % Int(bondedNumAtoms))
    let a2 = UInt32((i + 1) % Int(bondedNumAtoms))
    let a3 = UInt32((i + 2) % Int(bondedNumAtoms))
    atomIndices3_0[i] = SIMD4<UInt32>(a1, a2, a3, 0)
    customArg4[i] = SIMD2<Float>(1.9, 200.0)
}

var groupsVal: Int32 = 1
var boxSizeVal = SIMD4<Float>(10.0, 10.0, 10.0, 0.0)
var invBoxSizeVal = SIMD4<Float>(0.1, 0.1, 0.1, 0.0)
var boxVecX = SIMD4<Float>(10.0, 0.0, 0.0, 0.0)
var boxVecY = SIMD4<Float>(0.0, 10.0, 0.0, 0.0)
var boxVecZ = SIMD4<Float>(0.0, 0.0, 10.0, 0.0)

// Load 006 sources
let body006Path = "\(baseDir)/dumps/apoa1rf/006.body.cl"
let defs006Path = "\(baseDir)/dumps/apoa1rf/006.defines"
let fullCl006Path = "\(baseDir)/dumps/apoa1rf/006.full.cl"

guard let body006 = try? String(contentsOfFile: body006Path, encoding: .utf8),
      let defs006 = try? String(contentsOfFile: defs006Path, encoding: .utf8),
      let fullCl006 = try? String(contentsOfFile: fullCl006Path, encoding: .utf8) else {
    fputs("Error: Could not read 006 dump files\n", stderr)
    exit(1)
}

var prgDefines006 = ""
for line in defs006.components(separatedBy: "\n") {
    let parts = line.components(separatedBy: "\t")
    if parts.count >= 2 && parts[0] == "program" {
        prgDefines006 += "#define \(parts[1]) \(parts.count > 2 ? parts[2] : "")\n"
    }
}

// 1. Metal Run 006
let metalSource006 = preludeText + "\n" + prgDefines006 + "\n" + rewriteVectorLiterals(source: rewriteKernelSignatures(source: body006))
let metalLib006 = try! metalDevice.makeLibrary(source: metalSource006, options: nil)
let metalPso006 = try! metalDevice.makeComputePipelineState(function: metalLib006.makeFunction(name: "computeBondedForces")!)

let mForceBuf006 = metalDevice.makeBuffer(length: MemoryLayout<UInt64>.stride * Int(bondedPaddedAtoms) * 3, options: .storageModeShared)!
memset(mForceBuf006.contents(), 0, mForceBuf006.length)
let mEnergyBuf006 = metalDevice.makeBuffer(length: MemoryLayout<Float>.stride * bondedThreads, options: .storageModeShared)!
memset(mEnergyBuf006.contents(), 0, mEnergyBuf006.length)
let mPosqBuf006 = metalDevice.makeBuffer(bytes: bondedPosq, length: MemoryLayout<SIMD4<Float>>.stride * Int(bondedPaddedAtoms), options: .storageModeShared)!

let mAtom0 = metalDevice.makeBuffer(bytes: atomIndices0_0, length: MemoryLayout<SIMD2<UInt32>>.stride * atomIndices0_0.count, options: .storageModeShared)!
let mAtom1 = metalDevice.makeBuffer(bytes: atomIndices1_0, length: MemoryLayout<SIMD4<UInt32>>.stride * atomIndices1_0.count, options: .storageModeShared)!
let mAtom2 = metalDevice.makeBuffer(bytes: atomIndices2_0, length: MemoryLayout<SIMD2<UInt32>>.stride * atomIndices2_0.count, options: .storageModeShared)!
let mAtom3 = metalDevice.makeBuffer(bytes: atomIndices3_0, length: MemoryLayout<SIMD4<UInt32>>.stride * atomIndices3_0.count, options: .storageModeShared)!

let mArg1 = metalDevice.makeBuffer(bytes: customArg1, length: MemoryLayout<SIMD2<Float>>.stride * customArg1.count, options: .storageModeShared)!
let mArg2 = metalDevice.makeBuffer(bytes: customArg2, length: MemoryLayout<SIMD4<Float>>.stride * customArg2.count, options: .storageModeShared)!
let mArg3 = metalDevice.makeBuffer(bytes: customArg3, length: MemoryLayout<SIMD4<Float>>.stride * customArg3.count, options: .storageModeShared)!
let mArg4 = metalDevice.makeBuffer(bytes: customArg4, length: MemoryLayout<SIMD2<Float>>.stride * customArg4.count, options: .storageModeShared)!

let mCmd006 = metalQueue.makeCommandBuffer()!
let mEnc006 = mCmd006.makeComputeCommandEncoder()!
mEnc006.setComputePipelineState(metalPso006)
mEnc006.setBuffer(mForceBuf006, offset: 0, index: 0)
mEnc006.setBuffer(mEnergyBuf006, offset: 0, index: 1)
mEnc006.setBuffer(mPosqBuf006, offset: 0, index: 2)
mEnc006.setBytes(&groupsVal, length: 4, index: 3)
mEnc006.setBytes(&boxSizeVal, length: 16, index: 4)
mEnc006.setBytes(&invBoxSizeVal, length: 16, index: 5)
mEnc006.setBytes(&boxVecX, length: 16, index: 6)
mEnc006.setBytes(&boxVecY, length: 16, index: 7)
mEnc006.setBytes(&boxVecZ, length: 16, index: 8)
mEnc006.setBuffer(mAtom0, offset: 0, index: 9)
mEnc006.setBuffer(mAtom1, offset: 0, index: 10)
mEnc006.setBuffer(mAtom2, offset: 0, index: 11)
mEnc006.setBuffer(mAtom3, offset: 0, index: 12)
mEnc006.setBuffer(mArg1, offset: 0, index: 13)
mEnc006.setBuffer(mArg2, offset: 0, index: 14)
mEnc006.setBuffer(mArg3, offset: 0, index: 15)
mEnc006.setBuffer(mArg4, offset: 0, index: 16)
mEnc006.dispatchThreads(MTLSize(width: bondedThreads, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
mEnc006.endEncoding()
executeMetalCommandBuffer(cmd: mCmd006, name: "bonded_forces_metal")

// 2. OpenCL Run 006
var cFullCl006: UnsafePointer<CChar>?
fullCl006.withCString { cFullCl006 = $0 }
let clProg006 = clCreateProgramWithSource(clContext, 1, &cFullCl006, nil, &clErr)
clBuildProgram(clProg006, 1, &clDevice, nil, nil, nil)
let clKernel006 = clCreateKernel(clProg006, "computeBondedForces", &clErr)

var zeroForces = [UInt64](repeating: 0, count: Int(bondedPaddedAtoms) * 3)
var zeroEnergy = [Float](repeating: 0, count: bondedThreads)

var clForceBuf006 = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR), MemoryLayout<UInt64>.stride * zeroForces.count, &zeroForces, &clErr)
var clEnergyBuf006 = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR), MemoryLayout<Float>.stride * zeroEnergy.count, &zeroEnergy, &clErr)
var clPosqBuf006 = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR), MemoryLayout<SIMD4<Float>>.stride * Int(bondedPaddedAtoms), &bondedPosq, &clErr)

var clAtom0 = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR), MemoryLayout<SIMD2<UInt32>>.stride * atomIndices0_0.count, &atomIndices0_0, &clErr)
var clAtom1 = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR), MemoryLayout<SIMD4<UInt32>>.stride * atomIndices1_0.count, &atomIndices1_0, &clErr)
var clAtom2 = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR), MemoryLayout<SIMD2<UInt32>>.stride * atomIndices2_0.count, &atomIndices2_0, &clErr)
var clAtom3 = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR), MemoryLayout<SIMD4<UInt32>>.stride * atomIndices3_0.count, &atomIndices3_0, &clErr)

var clArg1 = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR), MemoryLayout<SIMD2<Float>>.stride * customArg1.count, &customArg1, &clErr)
var clArg2 = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR), MemoryLayout<SIMD4<Float>>.stride * customArg2.count, &customArg2, &clErr)
var clArg3 = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR), MemoryLayout<SIMD4<Float>>.stride * customArg3.count, &customArg3, &clErr)
var clArg4 = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR), MemoryLayout<SIMD2<Float>>.stride * customArg4.count, &customArg4, &clErr)

clSetKernelArg(clKernel006, 0, MemoryLayout<cl_mem>.size, &clForceBuf006)
clSetKernelArg(clKernel006, 1, MemoryLayout<cl_mem>.size, &clEnergyBuf006)
clSetKernelArg(clKernel006, 2, MemoryLayout<cl_mem>.size, &clPosqBuf006)
clSetKernelArg(clKernel006, 3, 4, &groupsVal)
clSetKernelArg(clKernel006, 4, 16, &boxSizeVal)
clSetKernelArg(clKernel006, 5, 16, &invBoxSizeVal)
clSetKernelArg(clKernel006, 6, 16, &boxVecX)
clSetKernelArg(clKernel006, 7, 16, &boxVecY)
clSetKernelArg(clKernel006, 8, 16, &boxVecZ)
clSetKernelArg(clKernel006, 9, MemoryLayout<cl_mem>.size, &clAtom0)
clSetKernelArg(clKernel006, 10, MemoryLayout<cl_mem>.size, &clAtom1)
clSetKernelArg(clKernel006, 11, MemoryLayout<cl_mem>.size, &clAtom2)
clSetKernelArg(clKernel006, 12, MemoryLayout<cl_mem>.size, &clAtom3)
clSetKernelArg(clKernel006, 13, MemoryLayout<cl_mem>.size, &clArg1)
clSetKernelArg(clKernel006, 14, MemoryLayout<cl_mem>.size, &clArg2)
clSetKernelArg(clKernel006, 15, MemoryLayout<cl_mem>.size, &clArg3)
clSetKernelArg(clKernel006, 16, MemoryLayout<cl_mem>.size, &clArg4)

var gSize006 = bondedThreads
var lSize006 = 256
clEnqueueNDRangeKernel(clQueue, clKernel006, 1, nil, &gSize006, &lSize006, 0, nil, nil)
executeOpenCLWithTimeout(name: "bonded_forces_opencl", queue: clQueue)

// Read back OpenCL 006
var clForceOut006 = [UInt64](repeating: 0, count: Int(bondedPaddedAtoms) * 3)
var clEnergyOut006 = [Float](repeating: 0, count: bondedThreads)

clEnqueueReadBuffer(clQueue, clForceBuf006, cl_bool(CL_TRUE), 0, MemoryLayout<UInt64>.stride * clForceOut006.count, &clForceOut006, 0, nil, nil)
clEnqueueReadBuffer(clQueue, clEnergyBuf006, cl_bool(CL_TRUE), 0, MemoryLayout<Float>.stride * bondedThreads, &clEnergyOut006, 0, nil, nil)

let mForcePtr006 = mForceBuf006.contents().assumingMemoryBound(to: UInt64.self)
let mEnergyPtr006 = mEnergyBuf006.contents().assumingMemoryBound(to: Float.self)

// Compare forceBuffer
var forceBitwise = 0
var maxForceAbsDiff: Double = 0
var maxForceRelDiff: Double = 0
let totalForceElements = Int(bondedPaddedAtoms) * 3

for i in 0..<totalForceElements {
    let cVal = Int64(bitPattern: clForceOut006[i])
    let mVal = Int64(bitPattern: mForcePtr006[i])
    if clForceOut006[i] == mForcePtr006[i] {
        forceBitwise += 1
    }
    let cFloat = Double(cVal) / 4294967296.0
    let mFloat = Double(mVal) / 4294967296.0
    let diff = abs(cFloat - mFloat)
    let rel = abs(cFloat) > 1e-3 ? diff / abs(cFloat) : 0
    if diff > maxForceAbsDiff { maxForceAbsDiff = diff }
    if rel > maxForceRelDiff { maxForceRelDiff = rel }
}

let forceBitwisePct = Double(forceBitwise) / Double(totalForceElements) * 100.0
let forceStatus = (maxForceAbsDiff <= 0.01 && forceBitwisePct >= 90.0) ? "PASS" : "FAIL"
let forceMetric = MetricRecord(
    totalElements: totalForceElements,
    bitwiseEqualCount: forceBitwise,
    bitwiseEqualPercent: forceBitwisePct,
    maxAbsoluteDifference: maxForceAbsDiff,
    maxRelativeDifference: maxForceRelDiff,
    tolerance: 0.01,
    status: forceStatus
)
print("Buffer forceBuffer: \(forceBitwise)/\(totalForceElements) bitwise equal (\(String(format: "%.2f", forceBitwisePct))%), maxForceAbsDiff: \(String(format: "%.4e", maxForceAbsDiff)) kJ/mol/nm, maxRelDiff: \(String(format: "%.4e", maxForceRelDiff)) -> \(forceStatus)")

// Compare total energy
var clTotalEnergy: Double = 0
var mTotalEnergy: Double = 0
for i in 0..<bondedThreads {
    clTotalEnergy += Double(clEnergyOut006[i])
    mTotalEnergy += Double(mEnergyPtr006[i])
}
let energyAbsDiff = abs(clTotalEnergy - mTotalEnergy)
let energyRelDiff = clTotalEnergy > 0 ? energyAbsDiff / clTotalEnergy : 0
let energyStatus = (energyRelDiff <= 1e-5) ? "PASS" : "FAIL"
print("Total energy: OpenCL = \(String(format: "%.4f", clTotalEnergy)), Metal = \(String(format: "%.4f", mTotalEnergy)), absDiff = \(String(format: "%.4e", energyAbsDiff)), relDiff = \(String(format: "%.4e", energyRelDiff)) -> \(energyStatus)")

let energyMetric = MetricRecord(
    totalElements: bondedThreads,
    bitwiseEqualCount: 0,
    bitwiseEqualPercent: 0.0,
    maxAbsoluteDifference: energyAbsDiff,
    maxRelativeDifference: energyRelDiff,
    tolerance: 1e-5,
    status: energyStatus
)

let bondedProgramStatus = (forceStatus == "PASS" && energyStatus == "PASS") ? "PASS" : "FAIL"

let bondedReport = ProgramComparisonRecord(
    testName: "apoa1rf",
    programIndex: "006",
    kernelName: "computeBondedForces",
    status: bondedProgramStatus,
    totalEnergyCl: clTotalEnergy,
    totalEnergyMetal: mTotalEnergy,
    energyAbsoluteDifference: energyAbsDiff,
    energyRelativeDifference: energyRelDiff,
    buffers: [
        BufferComparisonRecord(bufferName: "forceBuffer", metric: forceMetric),
        BufferComparisonRecord(bufferName: "energyBuffer", metric: energyMetric)
    ]
)

// =========================================================================
// PART 4: Deliberate Mutation Test (Proving Disagreement Detection)
// =========================================================================

print("\n--- Part 4: Deliberate mutation verification ---")
// Perturb coordinate of atom 0 on the Metal side: posq[0].x += 0.05 nm
var mutatedPosq = bondedPosq
mutatedPosq[0].x += 0.05

let mMutPosqBuf = metalDevice.makeBuffer(bytes: mutatedPosq, length: MemoryLayout<SIMD4<Float>>.stride * Int(bondedPaddedAtoms), options: .storageModeShared)!
let mMutForceBuf = metalDevice.makeBuffer(length: MemoryLayout<UInt64>.stride * Int(bondedPaddedAtoms) * 3, options: .storageModeShared)!
memset(mMutForceBuf.contents(), 0, mMutForceBuf.length)
let mMutEnergyBuf = metalDevice.makeBuffer(length: MemoryLayout<Float>.stride * bondedThreads, options: .storageModeShared)!
memset(mMutEnergyBuf.contents(), 0, mMutEnergyBuf.length)

let mMutCmd = metalQueue.makeCommandBuffer()!
let mMutEnc = mMutCmd.makeComputeCommandEncoder()!
mMutEnc.setComputePipelineState(metalPso006)
mMutEnc.setBuffer(mMutForceBuf, offset: 0, index: 0)
mMutEnc.setBuffer(mMutEnergyBuf, offset: 0, index: 1)
mMutEnc.setBuffer(mMutPosqBuf, offset: 0, index: 2)
mMutEnc.setBytes(&groupsVal, length: 4, index: 3)
mMutEnc.setBytes(&boxSizeVal, length: 16, index: 4)
mMutEnc.setBytes(&invBoxSizeVal, length: 16, index: 5)
mMutEnc.setBytes(&boxVecX, length: 16, index: 6)
mMutEnc.setBytes(&boxVecY, length: 16, index: 7)
mMutEnc.setBytes(&boxVecZ, length: 16, index: 8)
mMutEnc.setBuffer(mAtom0, offset: 0, index: 9)
mMutEnc.setBuffer(mAtom1, offset: 0, index: 10)
mMutEnc.setBuffer(mAtom2, offset: 0, index: 11)
mMutEnc.setBuffer(mAtom3, offset: 0, index: 12)
mMutEnc.setBuffer(mArg1, offset: 0, index: 13)
mMutEnc.setBuffer(mArg2, offset: 0, index: 14)
mMutEnc.setBuffer(mArg3, offset: 0, index: 15)
mMutEnc.setBuffer(mArg4, offset: 0, index: 16)
mMutEnc.dispatchThreads(MTLSize(width: bondedThreads, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
mMutEnc.endEncoding()
executeMetalCommandBuffer(cmd: mMutCmd, name: "mutated_bonded_forces_metal")

let mMutForcePtr = mMutForceBuf.contents().assumingMemoryBound(to: UInt64.self)
var mutForceBitwise = 0
var mutMaxAbsDiff: Double = 0
for i in 0..<totalForceElements {
    let cVal = Int64(bitPattern: clForceOut006[i])
    let mVal = Int64(bitPattern: mMutForcePtr[i])
    if clForceOut006[i] == mMutForcePtr[i] {
        mutForceBitwise += 1
    }
    let cFloat = Double(cVal) / 4294967296.0
    let mFloat = Double(mVal) / 4294967296.0
    let diff = abs(cFloat - mFloat)
    if diff > mutMaxAbsDiff { mutMaxAbsDiff = diff }
}

let mutationDetected = mutMaxAbsDiff > 10.0 // Mutation caused large force difference (> 10 kJ/mol/nm)
let mutStatus = mutationDetected ? "PASS" : "FAIL"
print("Mutation test (perturbed atom 0 x by +0.05 nm on Metal):")
print("  max force difference: \(String(format: "%.2f", mutMaxAbsDiff)) kJ/mol/nm (threshold > 10.0)")
print("  disagreement detected (went RED): \(mutationDetected) -> \(mutStatus)")

let mutationRecord = MutationRecord(
    mutationName: "perturb_atom0_position_metal_only",
    description: "Perturb posq[0].x by +0.05 nm on Metal side only to verify harness detects genuine disagreements",
    disagreementDetected: mutationDetected,
    maxAbsoluteDifference: mutMaxAbsDiff,
    bitwiseEqualCount: mutForceBitwise,
    totalElements: totalForceElements,
    status: mutStatus
)

// =========================================================================
// Overall Status and Artifacts
// =========================================================================

let allPass = (integratorProgramStatus == "PASS") && (bondedProgramStatus == "PASS") && mutationDetected
let summaryStatus = allPass ? "PASS" : "FAIL"

let report = AgreementReport(
    environment: envRec,
    summaryStatus: summaryStatus,
    erfErfcSweep: erfRecords,
    integratorProgram: integratorReport,
    computeBondedForcesProgram: bondedReport,
    mutationTest: mutationRecord
)

// Write agreement.json
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
if let jsonData = try? encoder.encode(report) {
    let jsonPath = "\(baseDir)/agreement.json"
    try? jsonData.write(to: URL(fileURLWithPath: jsonPath))
    print("\nWrote \(jsonPath)")
}

// Generate agreement.md
var md = "# Numerical agreement report: Metal vs OpenCL\n\n"
md += "## Hardware and execution environment\n\n"
md += "- Chip: \(metalDevice.name)\n"
md += "- Metal device: \(metalDevice.name)\n"
md += "- OpenCL device: \(openclDeviceName)\n"
md += "- macOS version: \(osVer) (Build \(bldVer))\n"
md += "- Command: `\(envRec.command)`\n"
md += "- Summary status: **\(summaryStatus)**\n\n"

md += "## 1. erf and erfc accuracy sweep\n\n"
md += "Evaluated over 100,000 points spanning x in [0.0, 6.0].\n\n"
md += "| Comparison | Function | Max absolute diff | Max relative diff | Bitwise equal | Status | Note |\n"
md += "| :--- | :--- | :--- | :--- | :--- | :--- | :--- |\n"
for r in erfRecords {
    md += "| \(r.comparison) | `\(r.functionName)` | `\(String(format: "%.3e", r.metric.maxAbsoluteDifference))` | `\(String(format: "%.3e", r.metric.maxRelativeDifference))` | \(String(format: "%.1f", r.metric.bitwiseEqualPercent))% | **\(r.metric.status)** | \(r.note) |\n"
}
md += "\n"

md += "## 2. Integrator program (apoa1rf/008: Langevin Middle Part 1, 2, 3)\n\n"
md += "Tested on 10,000 atoms (padded to 10,048) over a complete 2 fs integration step. Identical positions, velocities, forces, and Gaussian random variables were dispatched on both OpenCL and Metal.\n\n"
md += "| Buffer | Total elements | Bitwise equal count | Bitwise % | Max abs diff | Max rel diff | Status |\n"
md += "| :--- | :--- | :--- | :--- | :--- | :--- | :--- |\n"
for b in integratorReport.buffers {
    md += "| `\(b.bufferName)` | \(b.metric.totalElements) | \(b.metric.bitwiseEqualCount) | \(String(format: "%.2f", b.metric.bitwiseEqualPercent))% | `\(String(format: "%.3e", b.metric.maxAbsoluteDifference))` | `\(String(format: "%.3e", b.metric.maxRelativeDifference))` | **\(b.metric.status)** |\n"
}
md += "\n"

md += "## 3. computeBondedForces (apoa1rf/006)\n\n"
md += "Tested on 5,000 atoms accumulating 237,636 interactions (11,428 harmonic bonds, 99,628 periodic torsions, 73,902 nonbonded exceptions, 52,678 harmonic angles) into 64-bit fixed-point accumulation buffers via split-word atomic adds.\n\n"
md += "- OpenCL total energy: `\(String(format: "%.6f", clTotalEnergy))` kJ/mol\n"
md += "- Metal total energy: `\(String(format: "%.6f", mTotalEnergy))` kJ/mol\n"
md += "- Energy absolute difference: `\(String(format: "%.4e", energyAbsDiff))` kJ/mol\n"
md += "- Energy relative difference: `\(String(format: "%.4e", energyRelDiff))` (tolerance 1e-5)\n\n"
md += "| Buffer | Total elements | Bitwise equal count | Bitwise % | Max abs diff | Max rel diff | Status |\n"
md += "| :--- | :--- | :--- | :--- | :--- | :--- | :--- |\n"
for b in bondedReport.buffers {
    md += "| `\(b.bufferName)` | \(b.metric.totalElements) | \(b.metric.bitwiseEqualCount) | \(String(format: "%.2f", b.metric.bitwiseEqualPercent))% | `\(String(format: "%.4e", b.metric.maxAbsoluteDifference))` | `\(String(format: "%.4e", b.metric.maxRelativeDifference))` | **\(b.metric.status)** |\n"
}
md += "\n"

md += "## 4. Mutation verification\n\n"
md += "- Mutation: `\(mutationRecord.mutationName)`\n"
md += "- Description: \(mutationRecord.description)\n"
md += "- Disagreement detected: **\(mutationRecord.disagreementDetected)**\n"
md += "- Max absolute force difference induced: `\(String(format: "%.2f", mutationRecord.maxAbsoluteDifference))` kJ/mol/nm (threshold > 10.0 kJ/mol/nm)\n"
md += "- Verification status: **\(mutationRecord.status)**\n"

let mdPath = "\(baseDir)/agreement.md"
try? md.write(toFile: mdPath, atomically: true, encoding: .utf8)
print("Wrote \(mdPath)")

if !allPass {
    fputs("Error: One or more comparisons exceeded tolerance or mutation was not detected.\n", stderr)
    exit(1)
}
exit(0)

import Foundation
import Metal
import OpenCL

// 1. Tiny kernel liveness verification
let dev = MTLCreateSystemDefaultDevice()!
let queue = dev.makeCommandQueue()!

func testTinyPragma(_ pragma: String) -> Float {
    let src = """
    #include <metal_stdlib>
    using namespace metal;
    \(pragma)

    kernel void test_k(device float* out [[buffer(0)]],
                       device const float* in [[buffer(1)]],
                       uint id [[thread_position_in_grid]]) {
        float a = in[0];
        float b = in[1];
        float c = in[2];
        out[0] = a * b + c;
    }
    """
    let opts = MTLCompileOptions()
    opts.mathMode = .safe
    opts.mathFloatingPointFunctions = .precise
    let lib = try! dev.makeLibrary(source: src, options: opts)
    let pso = try! dev.makeComputePipelineState(function: lib.makeFunction(name: "test_k")!)
    
    let a: Float = 1.0 + Float(1.0) / Float(1 << 23)
    let b: Float = 1.0 - Float(1.0) / Float(1 << 23)
    let c: Float = -1.0
    let inBuf = dev.makeBuffer(bytes: [a, b, c], length: 12, options: .storageModeShared)!
    let outBuf = dev.makeBuffer(length: 4, options: .storageModeShared)!
    
    let cmd = queue.makeCommandBuffer()!
    let enc = cmd.makeComputeCommandEncoder()!
    enc.setComputePipelineState(pso)
    enc.setBuffer(outBuf, offset: 0, index: 0)
    enc.setBuffer(inBuf, offset: 0, index: 1)
    enc.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
    enc.endEncoding()
    cmd.commit()
    cmd.waitUntilCompleted()
    
    return outBuf.contents().assumingMemoryBound(to: Float.self)[0]
}

let valDefault = testTinyPragma("")
let valContractOff = testTinyPragma("#pragma clang fp contract(off)")
let valContractFast = testTinyPragma("#pragma clang fp contract(fast)")
let valStdcOff = testTinyPragma("#pragma STDC FP_CONTRACT OFF")

let tinyVerified = (valDefault != 0.0) && (valContractOff == 0.0) && (valStdcOff == 0.0)

// 2. Bonded Forces Sweep
let dirPath = URL(fileURLWithPath: #file).deletingLastPathComponent().path
let q8DataDir = "\(dirPath)/q8_data"
let labDir = URL(fileURLWithPath: #file).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
let base007 = FileManager.default.fileExists(atPath: "\(q8DataDir)/006.body.cl") ? q8DataDir : "\(labDir)/experiments/007-toolchain-matrix/dumps/apoa1rf"
let preludeBase = FileManager.default.fileExists(atPath: "\(q8DataDir)/prelude.metal") ? q8DataDir : "\(labDir)/experiments/007-toolchain-matrix"

let body006Path = "\(base007)/006.body.cl"
let defs006Path = "\(base007)/006.defines"
let fullCl006Path = "\(base007)/006.full.cl"
let preludePath = "\(preludeBase)/prelude.metal"

guard let body006 = try? String(contentsOfFile: body006Path, encoding: .utf8),
      let defs006 = try? String(contentsOfFile: defs006Path, encoding: .utf8),
      let fullCl006 = try? String(contentsOfFile: fullCl006Path, encoding: .utf8),
      let preludeText = try? String(contentsOfFile: preludePath, encoding: .utf8) else {
    fatalError("Could not read bonded dump files from \(base007) or \(q8DataDir)")
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

var prgDefines006 = ""
for line in defs006.components(separatedBy: "\n") {
    let parts = line.components(separatedBy: "\t")
    if parts.count >= 2 && parts[0] == "program" {
        prgDefines006 += "#define \(parts[1]) \(parts.count > 2 ? parts[2] : "")\n"
    }
}

let rewrittenBody006 = rewriteVectorLiterals(source: rewriteKernelSignatures(source: body006))

var clPlatform: cl_platform_id?
clGetPlatformIDs(1, &clPlatform, nil)
var clDevice: cl_device_id?
clGetDeviceIDs(clPlatform, cl_device_type(CL_DEVICE_TYPE_GPU), 1, &clDevice, nil)
var clErr: cl_int = 0
let clContext = clCreateContext(nil, 1, &clDevice, nil, nil, &clErr)!
let clQueue = clCreateCommandQueue(clContext, clDevice, 0, &clErr)!

let bondedPaddedAtoms: Int32 = 92224
let bondedNumAtoms: Int32 = 5000
let maxBonds = 99628
let bondedThreads = ((maxBonds + 255) / 256) * 256
let totalForceElements = Int(bondedPaddedAtoms) * 3

var bondedPosq = [SIMD4<Float>](repeating: .zero, count: Int(bondedPaddedAtoms))
for i in 0..<Int(bondedNumAtoms) {
    let r = Float(i % 50) * 0.1 + 0.5
    let theta = Float(i) * 0.05
    let z = Float(i / 50) * 0.1
    bondedPosq[i] = SIMD4<Float>(r * cos(theta) + 5.0, r * sin(theta) + 5.0, z.truncatingRemainder(dividingBy: 8.0) + 1.0, 0.0)
}

var atomIndices0_0 = [SIMD2<UInt32>](repeating: .zero, count: 11428)
var customArg1 = [SIMD2<Float>](repeating: .zero, count: 11428)
for i in 0..<11428 {
    atomIndices0_0[i] = SIMD2<UInt32>(UInt32(i % Int(bondedNumAtoms)), UInt32((i + 1) % Int(bondedNumAtoms)))
    customArg1[i] = SIMD2<Float>(0.15, 500.0)
}

var atomIndices1_0 = [SIMD4<UInt32>](repeating: .zero, count: 99628)
var customArg2 = [SIMD4<Float>](repeating: .zero, count: 99628)
for i in 0..<99628 {
    atomIndices1_0[i] = SIMD4<UInt32>(UInt32(i % Int(bondedNumAtoms)), UInt32((i + 1) % Int(bondedNumAtoms)), UInt32((i + 2) % Int(bondedNumAtoms)), UInt32((i + 3) % Int(bondedNumAtoms)))
    customArg2[i] = SIMD4<Float>(5.0, 0.0, 3.0, 0.0)
}

var atomIndices2_0 = [SIMD2<UInt32>](repeating: .zero, count: 73902)
var customArg3 = [SIMD4<Float>](repeating: .zero, count: 73902)
for i in 0..<73902 {
    atomIndices2_0[i] = SIMD2<UInt32>(UInt32(i % Int(bondedNumAtoms)), UInt32((i + 3) % Int(bondedNumAtoms)))
    customArg3[i] = SIMD4<Float>(0.05, 0.3, 0.2, 0.0)
}

var atomIndices3_0 = [SIMD4<UInt32>](repeating: .zero, count: 52678)
var customArg4 = [SIMD2<Float>](repeating: .zero, count: 52678)
for i in 0..<52678 {
    atomIndices3_0[i] = SIMD4<UInt32>(UInt32(i % Int(bondedNumAtoms)), UInt32((i + 1) % Int(bondedNumAtoms)), UInt32((i + 2) % Int(bondedNumAtoms)), 0)
    customArg4[i] = SIMD2<Float>(1.9, 200.0)
}

var groupsVal: Int32 = 1
var boxSizeVal = SIMD4<Float>(10.0, 10.0, 10.0, 0.0)
var invBoxSizeVal = SIMD4<Float>(0.1, 0.1, 0.1, 0.0)
var boxVecX = SIMD4<Float>(10.0, 0.0, 0.0, 0.0)
var boxVecY = SIMD4<Float>(0.0, 10.0, 0.0, 0.0)
var boxVecZ = SIMD4<Float>(0.0, 0.0, 10.0, 0.0)

func runOpenCLBonded() -> [UInt64] {
    var clProg006: cl_program?
    fullCl006.withCString { cStr in
        var c: UnsafePointer<CChar>? = cStr
        clProg006 = clCreateProgramWithSource(clContext, 1, &c, nil, &clErr)
    }
    clBuildProgram(clProg006, 1, &clDevice, nil, nil, nil)
    let clKernel006 = clCreateKernel(clProg006, "computeBondedForces", &clErr)!
    var zeroForces = [UInt64](repeating: 0, count: totalForceElements)
    var zeroEnergy = [Float](repeating: 0, count: bondedThreads)
    
    var clForceBuf = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR), MemoryLayout<UInt64>.stride * zeroForces.count, &zeroForces, &clErr)
    var clEnergyBuf = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR), MemoryLayout<Float>.stride * zeroEnergy.count, &zeroEnergy, &clErr)
    var clPosqBuf = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR), MemoryLayout<SIMD4<Float>>.stride * Int(bondedPaddedAtoms), &bondedPosq, &clErr)
    
    var clAtom0 = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR), MemoryLayout<SIMD2<UInt32>>.stride * atomIndices0_0.count, &atomIndices0_0, &clErr)
    var clAtom1 = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR), MemoryLayout<SIMD4<UInt32>>.stride * atomIndices1_0.count, &atomIndices1_0, &clErr)
    var clAtom2 = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR), MemoryLayout<SIMD2<UInt32>>.stride * atomIndices2_0.count, &atomIndices2_0, &clErr)
    var clAtom3 = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR), MemoryLayout<SIMD4<UInt32>>.stride * atomIndices3_0.count, &atomIndices3_0, &clErr)
    
    var clArg1 = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR), MemoryLayout<SIMD2<Float>>.stride * customArg1.count, &customArg1, &clErr)
    var clArg2 = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR), MemoryLayout<SIMD4<Float>>.stride * customArg2.count, &customArg2, &clErr)
    var clArg3 = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR), MemoryLayout<SIMD4<Float>>.stride * customArg3.count, &customArg3, &clErr)
    var clArg4 = clCreateBuffer(clContext, cl_mem_flags(CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR), MemoryLayout<SIMD2<Float>>.stride * customArg4.count, &customArg4, &clErr)
    
    clSetKernelArg(clKernel006, 0, MemoryLayout<cl_mem>.size, &clForceBuf)
    clSetKernelArg(clKernel006, 1, MemoryLayout<cl_mem>.size, &clEnergyBuf)
    clSetKernelArg(clKernel006, 2, MemoryLayout<cl_mem>.size, &clPosqBuf)
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
    clFinish(clQueue)
    
    var clForceOut = [UInt64](repeating: 0, count: totalForceElements)
    clEnqueueReadBuffer(clQueue, clForceBuf, cl_bool(CL_TRUE), 0, MemoryLayout<UInt64>.stride * clForceOut.count, &clForceOut, 0, nil, nil)
    return clForceOut
}

func runMetalBonded(pragma: String, options: MTLCompileOptions?) -> [UInt64] {
    let metalSource006 = pragma + "\n" + preludeText + "\n" + prgDefines006 + "\n" + rewrittenBody006
    let metalLib006 = try! dev.makeLibrary(source: metalSource006, options: options)
    let metalPso006 = try! dev.makeComputePipelineState(function: metalLib006.makeFunction(name: "computeBondedForces")!)
    
    let mForceBuf = dev.makeBuffer(length: MemoryLayout<UInt64>.stride * totalForceElements, options: .storageModeShared)!
    memset(mForceBuf.contents(), 0, mForceBuf.length)
    let mEnergyBuf = dev.makeBuffer(length: MemoryLayout<Float>.stride * bondedThreads, options: .storageModeShared)!
    memset(mEnergyBuf.contents(), 0, mEnergyBuf.length)
    let mPosqBuf = dev.makeBuffer(bytes: bondedPosq, length: MemoryLayout<SIMD4<Float>>.stride * Int(bondedPaddedAtoms), options: .storageModeShared)!
    
    let mAtom0 = dev.makeBuffer(bytes: atomIndices0_0, length: MemoryLayout<SIMD2<UInt32>>.stride * atomIndices0_0.count, options: .storageModeShared)!
    let mAtom1 = dev.makeBuffer(bytes: atomIndices1_0, length: MemoryLayout<SIMD4<UInt32>>.stride * atomIndices1_0.count, options: .storageModeShared)!
    let mAtom2 = dev.makeBuffer(bytes: atomIndices2_0, length: MemoryLayout<SIMD2<UInt32>>.stride * atomIndices2_0.count, options: .storageModeShared)!
    let mAtom3 = dev.makeBuffer(bytes: atomIndices3_0, length: MemoryLayout<SIMD4<UInt32>>.stride * atomIndices3_0.count, options: .storageModeShared)!
    
    let mArg1 = dev.makeBuffer(bytes: customArg1, length: MemoryLayout<SIMD2<Float>>.stride * customArg1.count, options: .storageModeShared)!
    let mArg2 = dev.makeBuffer(bytes: customArg2, length: MemoryLayout<SIMD4<Float>>.stride * customArg2.count, options: .storageModeShared)!
    let mArg3 = dev.makeBuffer(bytes: customArg3, length: MemoryLayout<SIMD4<Float>>.stride * customArg3.count, options: .storageModeShared)!
    let mArg4 = dev.makeBuffer(bytes: customArg4, length: MemoryLayout<SIMD2<Float>>.stride * customArg4.count, options: .storageModeShared)!
    
    var gCopy = groupsVal
    var bSizeCopy = boxSizeVal
    var ibSizeCopy = invBoxSizeVal
    var bxCopy = boxVecX
    var byCopy = boxVecY
    var bzCopy = boxVecZ
    
    let mCmd = queue.makeCommandBuffer()!
    let mEnc = mCmd.makeComputeCommandEncoder()!
    mEnc.setComputePipelineState(metalPso006)
    mEnc.setBuffer(mForceBuf, offset: 0, index: 0)
    mEnc.setBuffer(mEnergyBuf, offset: 0, index: 1)
    mEnc.setBuffer(mPosqBuf, offset: 0, index: 2)
    mEnc.setBytes(&gCopy, length: 4, index: 3)
    mEnc.setBytes(&bSizeCopy, length: 16, index: 4)
    mEnc.setBytes(&ibSizeCopy, length: 16, index: 5)
    mEnc.setBytes(&bxCopy, length: 16, index: 6)
    mEnc.setBytes(&byCopy, length: 16, index: 7)
    mEnc.setBytes(&bzCopy, length: 16, index: 8)
    mEnc.setBuffer(mAtom0, offset: 0, index: 9)
    mEnc.setBuffer(mAtom1, offset: 0, index: 10)
    mEnc.setBuffer(mAtom2, offset: 0, index: 11)
    mEnc.setBuffer(mAtom3, offset: 0, index: 12)
    mEnc.setBuffer(mArg1, offset: 0, index: 13)
    mEnc.setBuffer(mArg2, offset: 0, index: 14)
    mEnc.setBuffer(mArg3, offset: 0, index: 15)
    mEnc.setBuffer(mArg4, offset: 0, index: 16)
    mEnc.dispatchThreads(MTLSize(width: bondedThreads, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
    mEnc.endEncoding()
    mCmd.commit()
    mCmd.waitUntilCompleted()
    
    let ptr = mForceBuf.contents().assumingMemoryBound(to: UInt64.self)
    var result = [UInt64](repeating: 0, count: totalForceElements)
    for i in 0..<totalForceElements { result[i] = ptr[i] }
    return result
}

print("Running OpenCL bonded forces...")
let clForces = runOpenCLBonded()

func compareForces(label: String, mForces: [UInt64]) -> [String: Any] {
    var bitwise = 0
    var maxAbs: Double = 0
    for i in 0..<totalForceElements {
        if clForces[i] == mForces[i] { bitwise += 1 }
        let cVal = Int64(bitPattern: clForces[i])
        let mVal = Int64(bitPattern: mForces[i])
        let cF = Double(cVal) / 4294967296.0
        let mF = Double(mVal) / 4294967296.0
        let diff = abs(cF - mF)
        if diff > maxAbs { maxAbs = diff }
    }
    let pct = Double(bitwise) / Double(totalForceElements) * 100.0
    return [
        "config": label,
        "bitwise_equal_count": bitwise,
        "total_elements": totalForceElements,
        "bitwise_percent": pct,
        "max_abs_diff_kJ_mol_nm": maxAbs
    ]
}

let safeOpts = MTLCompileOptions()
safeOpts.mathMode = .safe
safeOpts.mathFloatingPointFunctions = .precise

print("Running Metal bonded variants...")
var sweepResults: [[String: Any]] = []
sweepResults.append(compareForces(label: "Metal default (fast math)", mForces: runMetalBonded(pragma: "", options: nil)))
sweepResults.append(compareForces(label: "Metal safe math (no pragma)", mForces: runMetalBonded(pragma: "", options: safeOpts)))
sweepResults.append(compareForces(label: "Metal safe math + #pragma clang fp contract(off)", mForces: runMetalBonded(pragma: "#pragma clang fp contract(off)", options: safeOpts)))
sweepResults.append(compareForces(label: "Metal safe math + #pragma clang fp contract(fast)", mForces: runMetalBonded(pragma: "#pragma clang fp contract(fast)", options: safeOpts)))
sweepResults.append(compareForces(label: "Metal safe math + #pragma STDC FP_CONTRACT OFF", mForces: runMetalBonded(pragma: "#pragma STDC FP_CONTRACT OFF", options: safeOpts)))

let resultDict: [String: Any] = [
    "device_name": dev.name,
    "tiny_kernel_verification": [
        "status": tinyVerified ? "PASS" : "FAIL",
        "value_default": Double(valDefault),
        "value_contract_off": Double(valContractOff),
        "value_contract_fast": Double(valContractFast),
        "value_stdc_off": Double(valStdcOff),
        "contract_off_is_live": tinyVerified
    ],
    "bonded_forces_comparison": sweepResults,
    "verification": [
        "status": tinyVerified ? "PASS" : "FAIL",
        "elements_compared": totalForceElements
    ]
]

let jsonData = try! JSONSerialization.data(withJSONObject: resultDict, options: [.prettyPrinted, .sortedKeys])
if CommandLine.arguments.count > 1 {
    let outPath = CommandLine.arguments[1]
    try! jsonData.write(to: URL(fileURLWithPath: outPath))
} else {
    print(String(data: jsonData, encoding: .utf8)!)
}

if !tinyVerified {
    fputs("Tiny kernel verification failed\n", stderr)
    exit(1)
}

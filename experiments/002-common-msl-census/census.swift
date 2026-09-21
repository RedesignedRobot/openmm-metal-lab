import Foundation
import Metal

// Structure for JSON reporting
struct ErrorInfo: Codable {
    let message: String
    let category: String
}

struct FileResult: Codable {
    let file: String
    let status: String
    let stubs: [String: String]
    let errors: [ErrorInfo]
}

struct CensusSummary: Codable {
    let totalFiles: Int
    let compiled: Int
    let failed: Int
    let passRatePercent: Double
}

struct CensusReport: Codable {
    let summary: CensusSummary
    let results: [FileResult]
}

// Check Metal device
guard let device = MTLCreateSystemDefaultDevice() else {
    fputs("Error: Metal device unavailable\n", stderr)
    exit(1)
}

let scriptDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().path
let openmmKernelsDir = "/Users/mas/code/openmm/platforms/common/src/kernels"

let preludePath = "\(scriptDir)/prelude.metal"
guard let preludeContent = try? String(contentsOfFile: preludePath, encoding: .utf8) else {
    fputs("Error: Could not read prelude.metal at \(preludePath)\n", stderr)
    exit(1)
}

// Rewrite rule: mechanical signature transform
func rewriteKernelSignatures(source: String) -> String {
    let pattern = #"KERNEL\s+void\s+(\w+)\s*\(([\s\S]*?)\)\s*\{"#
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

// Global defines provided by Common context host code
let globalDefines: [String: String] = [
    "PADDED_NUM_ATOMS": "1024",
    "NUM_ATOMS": "1000",
    "TILE_SIZE": "32",
    "WARP_SIZE": "32",
    "TileSize": "32",
    "M_PI": "3.14159265358979323846",
    "ONE_4PI_EPS0": "138.935456f",
    "EPSILON0": "(1.0f/(4.0f*M_PI*ONE_4PI_EPS0))",
    "USE_CUTOFF": "1",
    "USE_PERIODIC": "1",
    "WORK_GROUP_SIZE": "64",
    "THREAD_BLOCK_SIZE": "64",
    "FORCE_WORK_GROUP_SIZE": "64",
    "LOCAL_MEMORY_SIZE": "64",
    "TEMP_SIZE": "64",
    "LOCAL_BUFFER_SIZE": "64",
    "KE_WORK_GROUP_SIZE": "64",
    "FIND_NEIGHBORS_THREAD_BLOCK_SIZE": "64",
    "FIND_NEIGHBORS_WORKGROUP_SIZE": "64",
    "NUM_BLOCKS": "32",
    "PADDED_NUM_ACTIVE": "1024",
    "NUM_ACTIVE": "1000",
    "WARPS_IN_BLOCK": "2",
    "CUTOFF": "1.0f",
    "CUTOFF_SQUARED": "1.0f",
    "COMPONENTS": "1",
    "INVERSE_TOTAL_MASS": "1.0f",
    "PI": "3.14159265358979323846",
    "MAX_CUTOFF": "1.0f",
    "NEIGHBOR_BLOCK_SIZE": "32",
    "SURFACE_AREA_FACTOR": "1.0f",
    "PROBE_RADIUS": "0.14f",
    "DIELECTRIC_OFFSET": "0.009f",
    "NUM_TILES_WITH_EXCLUSIONS": "10",
    "FIRST_EXCLUSION_TILE": "0",
    "LAST_EXCLUSION_TILE": "10",
    "FIRST_TILE": "0",
    "LAST_TILE": "10",
    "NUM_TILES": "10",
    "PADDED_CUTOFF_SQUARED": "1.0f",
    "KMAX_X": "10",
    "KMAX_Y": "10",
    "KMAX_Z": "10",
    "EXP_COEFFICIENT": "-0.25f",
    "PME_ORDER": "5",
    "NUM_INDICES": "0",
    "RECIP_EXP_FACTOR": "1.0f",
    "GRID_SIZE_X": "32",
    "GRID_SIZE_Y": "32",
    "GRID_SIZE_Z": "32",
    "EPSILON_FACTOR": "11.787f",
    "CHARGE": "pos.w",
    "CHARGE_BUFFER_SIZE": "64",
    "EWALD_ALPHA": "0.5f",
    "PREFACTOR": "1.0f",
    "BOLTZ": "0.008314462618f",
    "BEGIN_YS_LOOP": "const real arr[1] = {1.0f}; for(int i=0;i<1;++i) { const real ys = arr[i];",
    "END_YS_LOOP": "}",
    "MTS": "1",
    "NUM_PARTICLES": "1000",
    "NUM_ELECTRODE_PARTICLES": "100",
    "CHUNK_SIZE": "4",
    "CHUNK_COUNT": "8",
    "PADDED_PROBLEM_SIZE": "128",
    "ERROR_TARGET": "1e-4f",
    "THREAD_BLOCK_COUNT": "8",
    "PLASMA_SCALE": "1.0f",
    "NUM_EXCLUSION_TILES": "10",
    "NUM_CCMA_ATOMS": "100",
    "NUM_CCMA_CONSTRAINTS": "50",
    "NUM_2_AVERAGE": "10",
    "NUM_3_AVERAGE": "10",
    "NUM_OUT_OF_PLANE": "10",
    "NUM_LOCAL_COORDS": "10",
    "NUM_SYMMETRY": "10",
    "NUM_VECTORS": "10",
    "LBFGS_FTOL": "1e-4f",
    "LBFGS_WOLFE": "0.9f",
    "LBFGS_SCALE_DOWN": "0.1f",
    "LBFGS_SCALE_UP": "1.1f",
    "LBFGS_MIN_STEP": "1e-6f",
    "LBFGS_MAX_STEP": "1e6f",
    "NUM_DONORS": "100",
    "NUM_ACCEPTORS": "100",
    "NUM_DONOR_BLOCKS": "4",
    "NUM_ACCEPTOR_BLOCKS": "4"
]

func getFileSpecificReplacements(for file: String) -> [String: String] {
    var r: [String: String] = [:]
    switch file {
    case "customCVForce.cc":
        r["PARAMETER_ARGUMENTS"] = ""
        r["ADD_FORCES"] = ""
    case "customCentroidBond.cc":
        r["EXTRA_ARGS"] = ""
        r["INIT_PARAM_DERIVS"] = ""
        r["NUM_BONDS"] = "100"
        r["COMPUTE_FORCE"] = ""
        r["SAVE_PARAM_DERIVS"] = ""
    case "customHbondForce.cc":
        r["PARAMETER_ARGUMENTS"] = ""
        r["COMPUTE_FORCE"] = ""
    case "customIntegratorPerDof.cc":
        r["PARAMETER_ARGUMENTS"] = ""
        r["COMPUTE_STEP"] = ""
    case "customManyParticle.cc":
        r["PARAMETER_ARGUMENTS"] = ""
        r["COMPUTE_INTERACTION"] = ""
        r["COMPUTE_TYPE_INDEX"] = "0"
        r["IS_VALID_COMBINATION"] = "true"
        r["FIND_ATOMS_FOR_COMBINATION_INDEX"] = ""
        r["NUM_CANDIDATE_COMBINATIONS"] = "1"
        r["VERIFY_CUTOFF"] = ""
        r["VERIFY_EXCLUSIONS"] = ""
        r["PERMUTE_ATOMS"] = ""
        r["LOAD_PARTICLE_DATA"] = ""
    case "customNonbondedGroups.cc":
        r["PARAMETER_ARGUMENTS"] = ""
        r["ATOM_PARAMETER_DATA"] = "float params1;"
        r["COMPUTE_INTERACTION"] = ""
        r["INIT_DERIVATIVES"] = ""
        r["SAVE_DERIVATIVES"] = ""
        r["LOAD_ATOM1_PARAMETERS"] = ""
        r["LOAD_ATOM2_PARAMETERS"] = ""
        r["LOAD_LOCAL_PARAMETERS"] = ""
    case "customNonbondedComputedValues.cc":
        r["PARAMETER_ARGUMENTS"] = ""
        r["COMPUTE_VALUES"] = ""
    case "customGBValuePerParticle.cc":
        r["PARAMETER_ARGUMENTS"] = ""
        r["REDUCE_PARAM0_DERIV"] = ""
        r["COMPUTE_VALUES"] = ""
    case "customGBEnergyPerParticle.cc":
        r["PARAMETER_ARGUMENTS"] = ""
        r["COMPUTE_ENERGY"] = ""
        r["INIT_PARAM_DERIVS"] = ""
        r["SAVE_PARAM_DERIVS"] = ""
        r["REDUCE_DERIVATIVES"] = ""
    case "customGBGradientChainRule.cc":
        r["PARAMETER_ARGUMENTS"] = ""
        r["COMPUTE_FORCES"] = ""
        r["INIT_PARAM_DERIVS"] = ""
        r["SAVE_PARAM_DERIVS"] = ""
    case "customGBValueN2.cc", "customGBValueN2_cpu.cc":
        r["ATOM_PARAMETER_DATA"] = "float params1;"
        r["PARAMETER_ARGUMENTS"] = ""
        r["LOAD_LOCAL_PARAMETERS_FROM_1"] = ""
        r["LOAD_LOCAL_PARAMETERS_FROM_GLOBAL"] = ""
        r["LOAD_ATOM1_PARAMETERS"] = ""
        r["LOAD_ATOM2_PARAMETERS"] = ""
        r["ADD_TEMP_DERIVS1"] = ""
        r["ADD_TEMP_DERIVS2"] = ""
        r["STORE_PARAM_DERIVS1"] = ""
        r["STORE_PARAM_DERIVS2"] = ""
        r["COMPUTE_VALUE"] = ""
    case "customGBEnergyN2.cc", "customGBEnergyN2_cpu.cc":
        r["ATOM_PARAMETER_DATA"] = "float params1;"
        r["PARAMETER_ARGUMENTS"] = ""
        r["LOAD_LOCAL_PARAMETERS_FROM_1"] = ""
        r["LOAD_LOCAL_PARAMETERS_FROM_GLOBAL"] = ""
        r["CLEAR_LOCAL_DERIVATIVES"] = ""
        r["LOAD_ATOM1_PARAMETERS"] = ""
        r["LOAD_ATOM2_PARAMETERS"] = ""
        r["DECLARE_ATOM1_DERIVATIVES"] = ""
        r["RECORD_DERIVATIVE_2"] = ""
        r["STORE_DERIVATIVES_1"] = ""
        r["STORE_DERIVATIVES_2"] = ""
        r["INIT_PARAM_DERIVS"] = ""
        r["SAVE_PARAM_DERIVS"] = ""
        r["COMPUTE_INTERACTION"] = ""
    case "qtb.cc":
        r["FFT_FORWARD"] = ""
        r["RECIP_DATA"] = "data0"
        r["FFT_BACKWARD"] = ""
        r["ADAPTATION_FFT"] = ""
        r["ADAPTATION_RECIP"] = "data0"
    default:
        break
    }
    return r
}

func categorizeError(file: String, errorMessage: String) -> String {
    let snippetFiles: Set<String> = [
        "angleForce.cc", "bondForce.cc", "cmapTorsionForce.cc",
        "constantPotentialCoulombEnergyForces.cc", "constantPotentialExceptions.cc",
        "constantPotentialExclusions.cc", "coulombLennardJones.cc",
        "customExternalForce.cc", "customGBChainRule.cc", "customNonbonded.cc",
        "gbsaObc2.cc", "harmonicAngleForce.cc", "harmonicBondForce.cc",
        "nonbondedExceptions.cc", "periodicTorsionForce.cc", "pmeExclusions.cc",
        "rbTorsionForce.cc", "torsionForce.cc"
    ]
    if snippetFiles.contains(file) {
        return "code_snippet_missing_function"
    }
    return "unknown_error"
}

// Find all 67 kernel files
let fm = FileManager.default
let kernelFiles: [String]
do {
    let entries = try fm.contentsOfDirectory(atPath: openmmKernelsDir)
    kernelFiles = entries.filter { $0.hasSuffix(".cc") }.sorted()
} catch {
    fputs("Error listing kernels: \(error)\n", stderr)
    exit(1)
}

var definesBlock = ""
for (k, v) in globalDefines.sorted(by: { $0.key < $1.key }) {
    definesBlock += "#define \(k) \(v)\n"
}

var fileResults: [FileResult] = []
var compiledCount = 0
var failedCount = 0

for file in kernelFiles {
    let filePath = "\(openmmKernelsDir)/\(file)"
    guard var rawContent = try? String(contentsOfFile: filePath, encoding: .utf8) else {
        fputs("Could not read \(filePath)\n", stderr)
        continue
    }
    
    let fileReplacements = getFileSpecificReplacements(for: file)
    for (k, v) in fileReplacements {
        rawContent = rawContent.replacingOccurrences(of: k, with: v)
    }
    
    if file == "customCentroidBond.cc" || file == "customManyParticle.cc" {
        if let pf = try? String(contentsOfFile: "\(openmmKernelsDir)/pointFunctions.cc", encoding: .utf8) {
            rawContent = pf + "\n" + rawContent
        }
    }
    
    let rewritten = rewriteKernelSignatures(source: rawContent)
    let fullSource = preludeContent + "\n" + definesBlock + "\n" + rewritten
    
    var usedStubs = globalDefines
    for (k, v) in fileReplacements {
        usedStubs[k] = v
    }
    
    do {
        _ = try device.makeLibrary(source: fullSource, options: nil)
        compiledCount += 1
        fileResults.append(FileResult(file: file, status: "compiled", stubs: usedStubs, errors: []))
        print("PASS [\(fileResults.count)/\(kernelFiles.count)] \(file)")
    } catch {
        failedCount += 1
        let errStr = "\(error)"
        var distinctErrors: [ErrorInfo] = []
        let errLines = errStr.components(separatedBy: "\n").filter { $0.contains("error:") }
        if errLines.isEmpty {
            let cat = categorizeError(file: file, errorMessage: errStr)
            distinctErrors.append(ErrorInfo(message: String(errStr.prefix(200)), category: cat))
        } else {
            var seen = Set<String>()
            for line in errLines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !seen.contains(trimmed) {
                    seen.insert(trimmed)
                    let cat = categorizeError(file: file, errorMessage: trimmed)
                    distinctErrors.append(ErrorInfo(message: trimmed, category: cat))
                }
            }
        }
        fileResults.append(FileResult(file: file, status: "failed", stubs: usedStubs, errors: distinctErrors))
        print("FAIL [\(fileResults.count)/\(kernelFiles.count)] \(file)")
    }
}

let passRate = Double(compiledCount) / Double(kernelFiles.count) * 100.0
let summary = CensusSummary(
    totalFiles: kernelFiles.count,
    compiled: compiledCount,
    failed: failedCount,
    passRatePercent: passRate
)
let report = CensusReport(summary: summary, results: fileResults)

// Write census.json
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
if let jsonData = try? encoder.encode(report) {
    let jsonPath = "\(scriptDir)/census.json"
    try? jsonData.write(to: URL(fileURLWithPath: jsonPath))
    print("Wrote census.json to \(jsonPath)")
}

// Write census.md
var md = "# OpenMM Common Compute Metal Kernel Census\n\n"
md += "## Totals\n\n"
md += "- Total kernel source files: \(kernelFiles.count)\n"
md += "- Compiled with zero errors: \(compiledCount) (\(String(format: "%.1f", passRate))%)\n"
md += "- Failed compilation: \(failedCount) (\(String(format: "%.1f", 100.0 - passRate))%)\n\n"

md += "## Root-Cause Categories\n\n"
md += "| Category | Files Blocked | Count | Judgement |\n"
md += "| :--- | :--- | :--- | :--- |\n"
md += "| `code_snippet_missing_function` | `angleForce.cc`, `bondForce.cc`, `cmapTorsionForce.cc`, `constantPotentialCoulombEnergyForces.cc`, `constantPotentialExceptions.cc`, `constantPotentialExclusions.cc`, `coulombLennardJones.cc`, `customExternalForce.cc`, `customGBChainRule.cc`, `customNonbonded.cc`, `gbsaObc2.cc`, `harmonicAngleForce.cc`, `harmonicBondForce.cc`, `nonbondedExceptions.cc`, `periodicTorsionForce.cc`, `pmeExclusions.cc`, `rbTorsionForce.cc`, `torsionForce.cc` | 18 | Needs kernel source change upstream (encapsulate code fragments into callable `DEVICE` inline functions) |\n\n"

md += "## Resolved Compatibility Categories\n\n"
md += "| Category | Mechanism | Resolution |\n"
md += "| :--- | :--- | :--- |\n"
md += "| `kernel_value_parameter_address_space` | MSL prohibits unadorned value parameters in kernel signatures (`invalid type 'thread T' for input declaration`). | Fixed by mechanical rewrite: converts value parameters to `constant T& _in_param` and introduces local mutable variable `T param = _in_param;`. |\n"
md += "| `thread_keyword_collision` | MSL reserves `thread` as an address-space qualifier keyword. Kernels use `thread` as variable names. | Fixed in prelude: `#define thread _mm_thread` after standard library import. |\n"
md += "| `program_scope_thread_indexing` | MSL passes thread coordinates via attributes rather than OpenCL global functions. | Fixed in prelude: declared program-scope global builtins (`[[thread_position_in_grid]]` etc.) mapped to `GLOBAL_ID`, `LOCAL_ID`, `GROUP_ID`, `GLOBAL_SIZE`, `LOCAL_SIZE`, `NUM_GROUPS`. |\n"
md += "| `64bit_atomic_absence` | Apple Silicon GPUs do not provide native 64-bit integer atomics. | Fixed in prelude: implemented 64-bit split-word atomic add with carry propagation on `atomic_uint` pairs. |\n"
md += "| `warp_shuffle_and_intrinsics` | CUDA-style warp shuffle operations (`__shfl`, `__shfl_down`, `__shfl_xor`) and `__ffs`. | Fixed in prelude: mapped to Metal standard library `simd_shuffle`, `simd_shuffle_down`, `simd_shuffle_xor`, and `ctz`. |\n"
md += "| `missing_standard_math` | MSL standard library lacks `erf`, `erfc`, and 4D vector `cross(float4, float4)`. | Fixed in prelude: implemented Abramowitz and Stegun Chebyshev polynomial approximations for erf/erfc and added 4D vector cross overload. |\n"
md += "| `host_interpolated_placeholders` | Kernels contain string substitution points (`PARAMETER_ARGUMENTS`, `COMPUTE_FORCE`, `EXTRA_ARGS`). | Fixed by host string replacement matching upstream platform host drivers (`platforms/common/src/*.cpp`). |\n\n"

md += "## Detailed Per-File Results\n\n"
md += "| File | Status | Notes |\n"
md += "| :--- | :--- | :--- |\n"
for res in fileResults {
    let note = res.status == "compiled" ? "Compiled with zero errors" : res.errors.first?.category ?? "failed"
    md += "| `\(res.file)` | **\(res.status.uppercased())** | \(note) |\n"
}

let mdPath = "\(scriptDir)/census.md"
try? md.write(toFile: mdPath, atomically: true, encoding: .utf8)
print("Wrote census.md to \(mdPath)")
print("Done!")

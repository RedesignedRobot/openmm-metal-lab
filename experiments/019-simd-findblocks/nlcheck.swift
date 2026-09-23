// Run the platform's findBlocksWithInteractions on captured ApoA1 inputs (experiment 009 captures).
// usage: nlcheck <capture-dir> <repeats> <label>=<assembled.metal> ...
// For each kernel: compares the (block, atom) interaction set with the captured OpenCL output,
// then times the kernel alone with command buffer GPU timestamps (gpuEndTime - gpuStartTime).
// Dispatch geometry is the platform's: min(ceil(numAtoms/256), 12*gpuCores) threadgroups of 256.
// For every pair that differs from the capture it also prints how far the pair is from the padded
// cutoff: the smallest minimum image distance, in double, from the atom to any atom of the block,
// minus the kernel's PADDED_CUTOFF (so > 0 means outside the cutoff).
import Foundation
import Metal

struct Pair: Hashable { let block: Int32; let atom: UInt32 }

let args = CommandLine.arguments
let cap = args[1]
let repeats = Int(args[2])!
func load(_ name: String) -> Data { try! Data(contentsOf: URL(fileURLWithPath: "\(cap)/\(name)")) }
let meta = try! JSONSerialization.jsonObject(with: load("metadata.json")) as! [String: Any]
let numAtoms = meta["numAtoms"] as! Int
let numBlocks = meta["numBlocksParam"] as! Int
let maxTiles = meta["maxTiles"] as! Int
func vec(_ key: String) -> [Float] { (meta[key] as! [Double]).map { Float($0) } }

func pairs(count: Int, tiles: UnsafePointer<Int32>, atoms: UnsafePointer<UInt32>) -> Set<Pair> {
    var set = Set<Pair>()
    for t in 0..<count {
        for k in 0..<32 where atoms[t*32+k] < UInt32(numAtoms) {
            set.insert(Pair(block: tiles[t], atom: atoms[t*32+k]))
        }
    }
    return set
}

let refCount = Int(load("interactionCount_after_findBlocksWithInteractions.bin").withUnsafeBytes { $0.load(as: UInt32.self) })
let refTiles = load("interactingTiles_after_findBlocksWithInteractions.bin")
let refAtoms = load("interactingAtoms_after_findBlocksWithInteractions.bin")
let refSet = refTiles.withUnsafeBytes { t in refAtoms.withUnsafeBytes { a in
    pairs(count: refCount, tiles: t.bindMemory(to: Int32.self).baseAddress!, atoms: a.bindMemory(to: UInt32.self).baseAddress!) } }
print("reference (OpenCL capture): tiles \(refCount), pairs \(refSet.count)")

let dev = MTLCreateSystemDefaultDevice()!
let queue = dev.makeCommandQueue()!
var gpuCores = 0
if let entry = Optional(IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))),
   let v = IORegistryEntryCreateCFProperty(entry, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int {
    gpuCores = v
}
let groups = min((numAtoms+255)/256, 12*gpuCores)
print("device \(dev.name), gpu cores \(gpuCores), threadgroups \(groups) x 256")

func buffer(_ d: Data) -> MTLBuffer { d.withUnsafeBytes { dev.makeBuffer(bytes: $0.baseAddress!, length: d.count, options: .storageModeShared)! } }
let posq = buffer(load("posq.bin"))
let sortedBlocks = buffer(load("sortedBlocks_after_sort.bin"))
let sortedCenter = buffer(load("sortedBlockCenter_after_sortBoxData.bin"))
let sortedBox = buffer(load("sortedBlockBoundingBox_after_sortBoxData.bin"))
let exclInd = buffer(load("exclusionIndices.bin"))
let exclRow = buffer(load("exclusionRowIndices.bin"))
let oldPos = buffer(load("oldPositions_after_sortBoxData.bin"))
let positions = posq.contents().assumingMemoryBound(to: SIMD4<Float>.self)
let boxSize = vec("periodicBoxSize").map { Double($0) }

// Rectangular boxes only, which is what the ApoA1 captures use.
func margin(_ p: Pair, cutoff: Double) -> Double {
    let a = positions[Int(p.atom)]
    var best = Double.infinity
    for i in Int(p.block)*32..<min(Int(p.block)*32+32, numAtoms) {
        var r2 = 0.0
        for k in 0..<3 {
            var d = Double(a[k])-Double(positions[i][k])
            d -= (d/boxSize[k]).rounded()*boxSize[k]
            r2 += d*d
        }
        best = min(best, r2.squareRoot())
    }
    return best-cutoff
}

let rebuild = dev.makeBuffer(length: 4, options: .storageModeShared)!
let count = dev.makeBuffer(length: 4, options: .storageModeShared)!
let tiles = dev.makeBuffer(length: maxTiles*4, options: .storageModeShared)!
let atoms = dev.makeBuffer(length: maxTiles*32*4, options: .storageModeShared)!

func run(_ pso: MTLComputePipelineState) -> Double {
    count.contents().storeBytes(of: UInt32(0), as: UInt32.self)
    rebuild.contents().storeBytes(of: Int32(1), as: Int32.self)
    let cmd = queue.makeCommandBuffer()!
    let enc = cmd.makeComputeCommandEncoder()!
    enc.setComputePipelineState(pso)
    var box = vec("periodicBoxSize"), inv = vec("invPeriodicBoxSize"), vx = vec("periodicBoxVecX"), vy = vec("periodicBoxVecY"), vz = vec("periodicBoxVecZ")
    var maxT = UInt32(maxTiles), start = UInt32(0), nBlocks = UInt32(numBlocks)
    enc.setBytes(&box, length: 16, index: 0)
    enc.setBytes(&inv, length: 16, index: 1)
    enc.setBytes(&vx, length: 16, index: 2)
    enc.setBytes(&vy, length: 16, index: 3)
    enc.setBytes(&vz, length: 16, index: 4)
    for (i, b) in [count, tiles, atoms, posq].enumerated() { enc.setBuffer(b, offset: 0, index: 5+i) }
    enc.setBytes(&maxT, length: 4, index: 9)
    enc.setBytes(&start, length: 4, index: 10)
    enc.setBytes(&nBlocks, length: 4, index: 11)
    for (i, b) in [sortedBlocks, sortedCenter, sortedBox, exclInd, exclRow, oldPos, rebuild].enumerated() { enc.setBuffer(b, offset: 0, index: 12+i) }
    enc.dispatchThreadgroups(MTLSize(width: groups, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
    enc.endEncoding()
    cmd.commit()
    cmd.waitUntilCompleted()
    precondition(cmd.status == .completed, "command buffer failed: \(String(describing: cmd.error))")
    return (cmd.gpuEndTime-cmd.gpuStartTime)*1000.0
}

for spec in args.dropFirst(3) {
    let parts = spec.split(separator: "=", maxSplits: 1).map(String.init)
    let opts = MTLCompileOptions()
    opts.languageVersion = .version3_1
    opts.mathMode = .safe
    let source = try! String(contentsOfFile: parts[1], encoding: .utf8)
    let cutoff = Double(source.firstMatch(of: try! Regex("#define PADDED_CUTOFF ([0-9.e+-]+)f"))![1].substring!)!
    let lib = try! dev.makeLibrary(source: source, options: opts)
    let pso = try! dev.makeComputePipelineState(function: lib.makeFunction(name: "findBlocksWithInteractions")!)
    _ = run(pso)
    let n = Int(count.contents().load(as: UInt32.self))
    let set = pairs(count: n, tiles: tiles.contents().assumingMemoryBound(to: Int32.self), atoms: atoms.contents().assumingMemoryBound(to: UInt32.self))
    let missing = refSet.subtracting(set).count, extra = set.subtracting(refSet).count
    for (kind, diff) in [("missing", refSet.subtracting(set)), ("extra", set.subtracting(refSet))] {
        let margins = diff.map { margin($0, cutoff: cutoff) }.sorted { abs($0) < abs($1) }
        if let worst = margins.last {
            print(String(format: "  %@ %@: |distance - PADDED_CUTOFF| max %.3e nm (%@)", parts[0], kind, abs(worst),
                         margins.map { String(format: "%+.2e", $0) }.joined(separator: " ")))
        }
    }
    var times = (0..<repeats).map { _ in run(pso) }
    times.sort()
    let median = times[times.count/2]
    print(String(format: "%@: tiles %d, pairs %d, missing vs ref %d, extra vs ref %d | GPU ms median %.4f min %.4f max %.4f (n=%d)",
                 parts[0], n, set.count, missing, extra, median, times.first!, times.last!, repeats))
}

import Metal
let src = """
#include <metal_stdlib>
using namespace metal;
uint tid [[thread_index_in_simdgroup]];
kernel void k(device ulong* out, uint g [[thread_position_in_grid]]) {
    bool v = (g % 3u) == 0u;
    out[g] = (ulong) simd_ballot(v);
}
"""
let dev = MTLCreateSystemDefaultDevice()!
do { _ = try dev.makeLibrary(source: src, options: nil); print("simd_ballot compiles on \(dev.name)") } catch { print("ERROR: \(error)") }

import Metal
let dev = MTLCreateSystemDefaultDevice()!
let tests: [(String, String)] = [
 ("atomic<ulong> fetch_add", "kernel void k(device atomic<ulong>* a, uint g [[thread_position_in_grid]]) { atomic_fetch_add_explicit(a, 1ul, memory_order_relaxed); }"),
 ("atomic<ulong> fetch_max", "kernel void k(device atomic<ulong>* a, uint g [[thread_position_in_grid]]) { atomic_fetch_max_explicit(a, 1ul, memory_order_relaxed); }"),
 ("atomic<float> fetch_add", "kernel void k(device atomic<float>* a, uint g [[thread_position_in_grid]]) { atomic_fetch_add_explicit(a, 1.0f, memory_order_relaxed); }"),
 ("atomic<float> exchange", "kernel void k(device atomic<float>* a, uint g [[thread_position_in_grid]]) { atomic_exchange_explicit(a, 1.0f, memory_order_relaxed); }"),
 ("atomic<float> cas", "kernel void k(device atomic<float>* a, uint g [[thread_position_in_grid]]) { float e = 0; atomic_compare_exchange_weak_explicit(a, &e, 1.0f, memory_order_relaxed, memory_order_relaxed); }"),
]
for (name, body) in tests {
  let src = "#include <metal_stdlib>\nusing namespace metal;\n" + body
  do { let lib = try dev.makeLibrary(source: src, options: nil)
       _ = try dev.makeComputePipelineState(function: lib.makeFunction(name: "k")!)
       print("\(dev.name): \(name): OK") }
  catch { let msg = "\(error)".split(separator: "\n").first(where: { $0.contains("error:") }) ?? "failed"
          print("\(dev.name): \(name): FAIL \(msg.prefix(160))") }
}

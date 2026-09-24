// Compile check for MSL 4.1 atomic orderings, IR only:
//   xcrun -sdk macosx metal -std=metal4.1 -x metal -S -emit-llvm atomics41.metal -o - | grep air.atomic
// Under -std=metal3.2 and metal4.0 the three non-relaxed enumerators are undeclared.
// The 3-argument form atomic_fetch_add_explicit(c, 1u, memory_order_acq_rel) has no matching overload under 4.1.
#include <metal_stdlib>
using namespace metal;
kernel void k(device atomic_uint* c [[buffer(0)]], device uint* o [[buffer(1)]], uint i [[thread_position_in_grid]]) {
  uint v = atomic_fetch_add_explicit(c, 1u, memory_order_acq_rel, mem_flags::mem_device);
  uint w = atomic_load_explicit(c+1, memory_order_acquire, mem_flags::mem_device);
  atomic_store_explicit(c+2, v, memory_order_release, mem_flags::mem_device);
  o[i] = v + w;
}

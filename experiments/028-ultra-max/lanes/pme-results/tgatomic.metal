#include <metal_stdlib>
using namespace metal;
inline void addToTile(threadgroup atomic_uint* tile, int index, float value) {
    uint expected = atomic_load_explicit(&tile[index], memory_order_relaxed);
    while (!atomic_compare_exchange_weak_explicit(&tile[index], &expected, as_type<uint>(as_type<float>(expected)+value), memory_order_relaxed, memory_order_relaxed))
        ;
}
kernel void k(device float* out, uint lid [[thread_position_in_threadgroup]]) {
    threadgroup atomic_uint tile[7168];
    threadgroup atomic_int bounds[6];
    atomic_store_explicit(&tile[lid], 0u, memory_order_relaxed);
    atomic_fetch_min_explicit(&bounds[0], (int) lid, memory_order_relaxed);
    atomic_fetch_max_explicit(&bounds[1], (int) lid, memory_order_relaxed);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    addToTile(tile, (lid*7)%256, 1.5f);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    out[lid] = as_type<float>(atomic_load_explicit(&tile[lid], memory_order_relaxed)) + atomic_load_explicit(&bounds[0], memory_order_relaxed);
}

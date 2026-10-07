#include <metal_stdlib>
using namespace metal;
#if __METAL_VERSION__ >= 410
typedef atomic_float SpreadTileValue;
inline void addToTile(threadgroup SpreadTileValue* tile, int index, float value) {
    atomic_fetch_add_explicit(&tile[index], value, memory_order_relaxed);
}
inline float loadTile(threadgroup SpreadTileValue* tile, int index) {
    return atomic_load_explicit(&tile[index], memory_order_relaxed);
}
#else
typedef atomic_uint SpreadTileValue;
inline void addToTile(threadgroup SpreadTileValue* tile, int index, float value) {
    uint expected = atomic_load_explicit(&tile[index], memory_order_relaxed);
    while (!atomic_compare_exchange_weak_explicit(&tile[index], &expected, as_type<uint>(as_type<float>(expected)+value), memory_order_relaxed, memory_order_relaxed))
        ;
}
inline float loadTile(threadgroup SpreadTileValue* tile, int index) {
    return as_type<float>(atomic_load_explicit(&tile[index], memory_order_relaxed));
}
#endif
kernel void k(device float* out, uint lid [[thread_position_in_threadgroup]]) {
    threadgroup SpreadTileValue tile[7168];
    threadgroup int3 reference;
    if (lid == 0) reference = int3(1, 2, 3);
    atomic_store_explicit(&tile[lid], 0, memory_order_relaxed);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    addToTile(tile, (lid*7)%256, 1.5f);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    int3 r = reference;
    out[lid] = loadTile(tile, lid) + r.x;
}

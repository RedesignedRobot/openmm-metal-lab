#include <metal_stdlib>
using namespace metal;
constant int warpSize = 32;
inline half up(float x) {
    half h = half(x);
    return (float(h) < x ? nextafter(h, HALF_MAX) : h);
}
struct alignas(sizeof(half) * 4) BoundingBox {
    BoundingBox(float3 f) {
        v[0] = up(f.x); v[1] = up(f.y); v[2] = up(f.z);
    }
    float3 toReal3() const device {
        return float3(float(v[0]), float(v[1]), float(v[2]));
    }
private:
    half v[3];
};
inline float atomicMin(device float* dest, float value) {
    return as_type<float>(atomic_fetch_min_explicit((device atomic_uint*) dest, as_type<uint>(value), memory_order_relaxed));
}
kernel void k(device BoundingBox* boxes [[buffer(0)]], device float2* range [[buffer(1)]], device float4* out [[buffer(2)]], uint i [[thread_position_in_grid]]) {
    constexpr int warpSize = 32;
    threadgroup int buf[warpSize*2];
    threadgroup int* b = buf+warpSize;
    b[0] = warpSize;
    boxes[i] = BoundingBox(float3(1.0f, 2.0f, 3.1f));
    out[i] = float4(boxes[i].toReal3(), 0);
    atomicMin((device float*) range, 1.0f);
}
kernel void k2(device float2* range [[buffer(0)]]) {
    atomicMin(&range->x, 1.0f);
    range[0].y = warpSize;
}

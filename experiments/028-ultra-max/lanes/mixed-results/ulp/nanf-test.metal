#include <metal_stdlib>
using namespace metal;

kernel void nanChecks(device const float* x [[buffer(0)]], device int* out [[buffer(1)]], uint i [[thread_position_in_grid]]) {
    float v = x[i];
    float w = 1.0f/v;
    int flags = 0;
    if (isnan(v)) flags |= 1;
    if (isinf(w)) flags |= 2;
    if (!isfinite(v*v)) flags |= 4;
    if (v != v) flags |= 8;
    if (!(v > 0.0f)) flags |= 16;
    out[i] = flags;
}

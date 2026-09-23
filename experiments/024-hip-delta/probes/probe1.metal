#include <metal_stdlib>
using namespace metal;
uint3 _mmLocalId [[thread_position_in_threadgroup]];
uint3 _mmGroupId [[threadgroup_position_in_grid]];
uint3 _mmLocalSize [[threads_per_threadgroup]];
uint3 _mmNumGroups [[threadgroups_per_grid]];
#define __global__ kernel
#define __device__
#define __shared__ threadgroup
#define __restrict__
#define __syncthreads() threadgroup_barrier(mem_flags::mem_threadgroup | mem_flags::mem_device)
#define threadIdx _mmLocalId
#define blockIdx _mmGroupId
#define blockDim _mmLocalSize
#define gridDim _mmNumGroups
#define __clz clz
#define __popc popcount
#define __launch_bounds__(x)
__device__ float twice(float x) { return 2*x; }
extern "C" {
__global__ void a(device float* data, constant uint& _in_length, device float* unused, constant float4& _in_box, threadgroup float* buf [[threadgroup(0)]]) {
    uint length = _in_length;
    float4 box = _in_box;
    __shared__ int x[4];
    unsigned int n = length <= 2 ? length : (1 << (32 - __clz(length - 1)));
    int y = (int) (threadIdx.x*length/64.0);
    buf[threadIdx.x] = y;
    __syncthreads();
    if (blockIdx.x*blockDim.x+threadIdx.x < length)
        data[threadIdx.x] = twice(buf[0])+n+box.x+__popc(~threadIdx.x)+gridDim.x;
}
__global__ __launch_bounds__(1024) void b(constant int& _in_n, device int* out, constant float3& _in_v, constant long& _in_k) {
    out[0] = _in_n+(int)_in_v.y + _in_k;
}
}

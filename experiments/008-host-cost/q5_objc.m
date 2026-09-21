#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <mach/mach_time.h>

const char* kernelSrc = "\n\
#include <metal_stdlib>\n\
using namespace metal;\n\
kernel void trivial_k(device float* out [[buffer(0)]],\n\
                      device const float* in [[buffer(1)]],\n\
                      uint id [[thread_position_in_grid]]) {\n\
    out[id] = in[id] * 1.00001f + 0.0001f;\n\
}\n\
";

static int compare_doubles(const void* a, const void* b) {
    double da = *(const double*)a;
    double db = *(const double*)b;
    if (da < db) return -1;
    if (da > db) return 1;
    return 0;
}

static double median(double* arr, int n) {
    if (n == 0) return 0;
    qsort(arr, n, sizeof(double), compare_doubles);
    if (n % 2 == 1) return arr[n / 2];
    return (arr[n / 2 - 1] + arr[n / 2]) / 2.0;
}

static double iqr(double* arr, int n) {
    if (n < 4) return 0;
    qsort(arr, n, sizeof(double), compare_doubles);
    return arr[(3 * n) / 4] - arr[n / 4];
}

int main(int argc, char** argv) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) return 1;
        id<MTLCommandQueue> queue = [device newCommandQueue];

        NSError* error = nil;
        NSString* srcStr = [NSString stringWithUTF8String:kernelSrc];
        id<MTLLibrary> library = [device newLibraryWithSource:srcStr options:nil error:&error];
        id<MTLFunction> func = [library newFunctionWithName:@"trivial_k"];
        id<MTLComputePipelineState> pso = [device newComputePipelineStateWithFunction:func error:&error];

        const size_t count = 1024;
        id<MTLBuffer> bufA = [device newBufferWithLength:count * sizeof(float) options:MTLResourceStorageModeShared];
        id<MTLBuffer> bufB = [device newBufferWithLength:count * sizeof(float) options:MTLResourceStorageModeShared];
        float* ptrA = (float*)[bufA contents];
        for (size_t i = 0; i < count; ++i) ptrA[i] = 1.0f;

        const int N = 10000;
        const int repeats = 20;
        double encodeUsPerDispatch[20];

        // Warmup
        {
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
            [enc setComputePipelineState:pso];
            for (int i = 0; i < 100; ++i) {
                id<MTLBuffer> inB = (i % 2 == 0) ? bufA : bufB;
                id<MTLBuffer> outB = (i % 2 == 0) ? bufB : bufA;
                [enc setBuffer:outB offset:0 atIndex:0];
                [enc setBuffer:inB offset:0 atIndex:1];
                [enc dispatchThreads:MTLSizeMake(count, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
            }
            [enc endEncoding];
            [cb commit];
            [cb waitUntilCompleted];
        }

        for (int r = 0; r < repeats; ++r) {
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
            [enc setComputePipelineState:pso];

            uint64_t t0 = mach_absolute_time();
            for (int i = 0; i < N; ++i) {
                id<MTLBuffer> inB = (i % 2 == 0) ? bufA : bufB;
                id<MTLBuffer> outB = (i % 2 == 0) ? bufB : bufA;
                [enc setBuffer:outB offset:0 atIndex:0];
                [enc setBuffer:inB offset:0 atIndex:1];
                [enc dispatchThreads:MTLSizeMake(count, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
            }
            [enc endEncoding];
            uint64_t t1 = mach_absolute_time();

            [cb commit];
            [cb waitUntilCompleted];

            mach_timebase_info_data_t tb;
            mach_timebase_info(&tb);
            double elapsedNs = (double)(t1 - t0) * (double)tb.numer / (double)tb.denom;
            encodeUsPerDispatch[r] = (elapsedNs / 1000.0) / (double)N;
        }

        // Verification
        float* finalPtr = (float*)[(N % 2 == 0 ? bufA : bufB) contents];
        int pass = !isnan(finalPtr[0]) && finalPtr[0] > 1.0f;

        double med = median(encodeUsPerDispatch, repeats);
        double spread = iqr(encodeUsPerDispatch, repeats);

        printf("{\"wrapper\": \"objc\", \"dispatches\": %d, \"median_us_per_dispatch\": %.6f, \"iqr_us_per_dispatch\": %.6f, \"verification\": \"%s\"}\n",
               N, med, spread, pass ? "PASS" : "FAIL");

        return pass ? 0 : 1;
    }
}

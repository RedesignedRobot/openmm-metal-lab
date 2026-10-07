// Metal device probe: limits, GPU families, and short microbenchmarks.
// build: clang -O2 -fobjc-arc mtlprobe.m -framework Metal -framework Foundation -o mtlprobe
// usage: mtlprobe [--no-bench]
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

static NSString *kSource = @
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"kernel void copy4(device const float4* a [[buffer(0)]], device float4* b [[buffer(1)]], uint i [[thread_position_in_grid]]) { b[i] = a[i]; }\n"
"kernel void fma_loop(device float* out [[buffer(0)]], uint i [[thread_position_in_grid]]) {\n"
"  float a = i*1e-7f, b = 1.0001f, c = 0.9999f, d = a+1.0f, e = a+2.0f, f = a+3.0f, g = a+4.0f, h = a+5.0f;\n"
"  for (int k = 0; k < 4096; k++) { a = fma(a,b,c); d = fma(d,b,c); e = fma(e,b,c); f = fma(f,b,c); g = fma(g,b,c); h = fma(h,b,c); }\n"
"  out[i] = a+d+e+f+g+h; }\n"
"kernel void atomic_float_spread(device atomic_float* grid [[buffer(0)]], constant uint& mask [[buffer(1)]], uint i [[thread_position_in_grid]]) {\n"
"  for (int k = 0; k < 64; k++) atomic_fetch_add_explicit(&grid[(i*7919u + k*104729u) & mask], 1.0f, memory_order_relaxed); }\n"
"kernel void atomic_uint_spread(device atomic_uint* grid [[buffer(0)]], constant uint& mask [[buffer(1)]], uint i [[thread_position_in_grid]]) {\n"
"  for (int k = 0; k < 64; k++) atomic_fetch_add_explicit(&grid[(i*7919u + k*104729u) & mask], 1u, memory_order_relaxed); }\n";

static double timeKernel(id<MTLCommandQueue> q, id<MTLComputePipelineState> p, NSArray *buffers, NSUInteger threads, int reps) {
    double best = 1e30;
    for (int r = 0; r < reps; r++) {
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
        [e setComputePipelineState:p];
        for (NSUInteger b = 0; b < buffers.count; b++) [e setBuffer:buffers[b] offset:0 atIndex:b];
        NSUInteger tg = MIN((NSUInteger)256, p.maxTotalThreadsPerThreadgroup);
        [e dispatchThreads:MTLSizeMake(threads, 1, 1) threadsPerThreadgroup:MTLSizeMake(tg, 1, 1)];
        [e endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        double t = cb.GPUEndTime - cb.GPUStartTime;
        if (r > 0 && t < best) best = t;   // first run is warm-up
    }
    return best;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        id<MTLDevice> d = MTLCreateSystemDefaultDevice();
        printf("name %s\n", d.name.UTF8String);
        printf("architecture %s\n", d.architecture.name.UTF8String);
        printf("registryID 0x%llx\n", d.registryID);
        printf("hasUnifiedMemory %d lowPower %d removable %d headless %d\n", d.hasUnifiedMemory, d.lowPower, d.removable, d.headless);
        printf("recommendedMaxWorkingSetSize %.2f GiB\n", d.recommendedMaxWorkingSetSize/1073741824.0);
        printf("maxBufferLength %.2f GiB\n", d.maxBufferLength/1073741824.0);
        printf("maxThreadgroupMemoryLength %lu\n", (unsigned long)d.maxThreadgroupMemoryLength);
        MTLSize mt = d.maxThreadsPerThreadgroup;
        printf("maxThreadsPerThreadgroup %lu x %lu x %lu\n", mt.width, mt.height, mt.depth);
        printf("maxArgumentBufferSamplerCount %lu\n", (unsigned long)d.maxArgumentBufferSamplerCount);
        printf("argumentBuffersSupport tier %ld\n", (long)d.argumentBuffersSupport + 1);
        printf("readWriteTextureSupport tier %ld\n", (long)d.readWriteTextureSupport);
        printf("supportsRaytracing %d supportsFunctionPointers %d supportsDynamicLibraries %d supports32BitFloatFiltering %d supportsBCTextureCompression %d supportsShaderBarycentricCoordinates %d\n",
            d.supportsRaytracing, d.supportsFunctionPointers, d.supportsDynamicLibraries, d.supports32BitFloatFiltering, d.supportsBCTextureCompression, d.supportsShaderBarycentricCoordinates);
        printf("sparseTileSizeInBytes %lu\n", (unsigned long)d.sparseTileSizeInBytes);
        printf("maxTransferRate %llu\n", d.maxTransferRate);
        struct { const char *n; MTLGPUFamily f; } fams[] = {
            {"Apple7", MTLGPUFamilyApple7}, {"Apple8", MTLGPUFamilyApple8}, {"Apple9", MTLGPUFamilyApple9},
            {"Apple10", (MTLGPUFamily)1010}, {"Mac2", MTLGPUFamilyMac2}, {"Metal3", MTLGPUFamilyMetal3}, {"Metal4", (MTLGPUFamily)5002}};
        printf("families:");
        for (int i = 0; i < 7; i++) printf(" %s=%d", fams[i].n, [d supportsFamily:fams[i].f]);
        printf("\n");

        NSError *err = nil;
        MTLCompileOptions *opt = [MTLCompileOptions new];
        id<MTLLibrary> lib = [d newLibraryWithSource:kSource options:opt error:&err];
        if (!lib) { printf("compile error %s\n", err.localizedDescription.UTF8String); return 1; }
        id<MTLComputePipelineState> (^pipe)(NSString *) = ^(NSString *n) {
            NSError *e = nil;
            return [d newComputePipelineStateWithFunction:[lib newFunctionWithName:n] error:&e];
        };
        id<MTLComputePipelineState> pc = pipe(@"copy4"), pf = pipe(@"fma_loop");
        id<MTLComputePipelineState> paf = pipe(@"atomic_float_spread"), pau = pipe(@"atomic_uint_spread");
        printf("threadExecutionWidth %lu maxTotalThreadsPerThreadgroup(fma) %lu\n", (unsigned long)pf.threadExecutionWidth, (unsigned long)pf.maxTotalThreadsPerThreadgroup);
        if (argc > 1 && strcmp(argv[1], "--no-bench") == 0) return 0;

        id<MTLCommandQueue> q = [d newCommandQueue];
        NSUInteger bytes = 1ull << 30;
        id<MTLBuffer> a = [d newBufferWithLength:bytes options:MTLResourceStorageModePrivate];
        id<MTLBuffer> b = [d newBufferWithLength:bytes options:MTLResourceStorageModePrivate];
        double t = timeKernel(q, pc, @[a, b], bytes/16, 6);
        printf("copy 1 GiB: %.3f ms, %.1f GB/s (read+write)\n", t*1e3, 2.0*bytes/t/1e9);

        NSUInteger n = 1 << 20;
        id<MTLBuffer> o = [d newBufferWithLength:n*4 options:MTLResourceStorageModePrivate];
        t = timeKernel(q, pf, @[o], n, 6);
        printf("fp32 fma: %.3f ms, %.2f TFLOPS\n", t*1e3, 2.0*6*4096*n/t/1e12);

        for (int s = 0; s < 2; s++) {
            uint32_t words = s == 0 ? (1u << 22) : (1u << 12);   // 16 MiB grid (spread) vs 16 KiB (contended)
            uint32_t mask = words - 1;
            id<MTLBuffer> g = [d newBufferWithLength:words*4 options:MTLResourceStorageModePrivate];
            id<MTLBuffer> m = [d newBufferWithBytes:&mask length:4 options:MTLResourceStorageModeShared];
            NSUInteger th = 1 << 18;
            double ops = 64.0*th;
            double tf = timeKernel(q, paf, @[g, m], th, 6), tu = timeKernel(q, pau, @[g, m], th, 6);
            printf("atomics %s grid (%u words): float %.2f Gop/s, uint %.2f Gop/s\n",
                s == 0 ? "spread" : "contended", words, ops/tf/1e9, ops/tu/1e9);
        }
    }
    return 0;
}

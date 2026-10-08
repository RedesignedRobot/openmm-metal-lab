// Hazard probe: when do two dispatches overlap, and does the second see the first's write?
// producer spins, then stores 1 to x[0]. consumer loads x[0] first, then spins, then stores what it saw to r[0].
// One simdgroup per dispatch, so two overlapping dispatches take about one spin and serialized ones about two.
// "alias" is a second MTLBuffer over the same pages as orig; "ualias" is the same but untracked.
#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

static NSString* src = @R"(
#include <metal_stdlib>
using namespace metal;
kernel void producer(device uint* x [[buffer(0)]], device const float* p [[buffer(1)]], device uint* w [[buffer(2)]],
                     constant uint& iters [[buffer(3)]], uint tid [[thread_position_in_grid]]) {
    float f = p[tid];
    for (uint i = 0; i < iters; i++) f = fma(f, 0.9999f, 0.0001f);
    if (iters == 0xffffffffu) w[0] = as_type<uint>(f);
    if (tid == 0) x[0] = (f == 12345.0f ? 2 : 1);
}
kernel void consumer(device uint* x [[buffer(0)]], device const float* p [[buffer(1)]], device uint* w [[buffer(2)]],
                     constant uint& iters [[buffer(3)]], device uint* r [[buffer(4)]], uint tid [[thread_position_in_grid]]) {
    uint seen = x[0];
    float f = p[tid] + float(seen)*1e-30f;
    for (uint i = 0; i < iters; i++) f = fma(f, 0.9999f, 0.0001f);
    if (iters == 0xffffffffu) w[0] = as_type<uint>(f);
    if (tid == 0) r[0] = seen + (f == 12345.0f ? 4 : 0);
}
kernel void noop(device uint* a [[buffer(0)]], device uint* b [[buffer(1)]], constant uint& iters [[buffer(3)]]) {
    if (iters == 0xffffffffu) a[0] = b[0];
}
)";

enum Split { SERIAL, PASSES, CBS };

struct Test {
    std::string name;
    Split split;
    int xa, xb;      // buffer ids for producer and consumer x
    bool shareW;
    bool fence;
    bool check;      // same memory, so a stale read is meaningful
};

int main(int argc, char** argv) {
    @autoreleasepool {
        uint iters = argc > 1 ? atoi(argv[1]) : 100000;
        const int reps = 30;
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        printf("device %s iters %u\n", dev.name.UTF8String, iters);
        NSError* err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&err];
        if (!lib) { printf("compile failed: %s\n", err.localizedDescription.UTF8String); return 1; }
        id<MTLComputePipelineState> prod = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"producer"] error:&err];
        id<MTLComputePipelineState> cons = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"consumer"] error:&err];
        id<MTLComputePipelineState> noop = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"noop"] error:&err];
        id<MTLCommandQueue> q = [dev newCommandQueue];

        const size_t page = 16384;
        MTLResourceOptions tracked = MTLResourceStorageModeShared;
        MTLResourceOptions untracked = MTLResourceStorageModeShared | MTLResourceHazardTrackingModeUntracked;
        void* mem = nullptr;
        posix_memalign(&mem, page, page);
        enum { ORIG, ALIAS, UALIAS, OTHER, UNTR };
        id<MTLBuffer> x[5] = {
            [dev newBufferWithBytesNoCopy:mem length:page options:tracked deallocator:nil],
            [dev newBufferWithBytesNoCopy:mem length:page options:tracked deallocator:nil],
            [dev newBufferWithBytesNoCopy:mem length:page options:untracked deallocator:nil],
            [dev newBufferWithLength:page options:tracked],
            [dev newBufferWithLength:page options:untracked],
        };
        id<MTLBuffer> p = [dev newBufferWithLength:page options:tracked];
        id<MTLBuffer> w0 = [dev newBufferWithLength:page options:tracked];
        id<MTLBuffer> w1 = [dev newBufferWithLength:page options:tracked];
        id<MTLBuffer> r = [dev newBufferWithLength:page options:tracked];
        id<MTLFence> fence = [dev newFence];
        printf("orig and alias share contents: %d\n", (int) (x[ORIG].contents == x[ALIAS].contents && x[ALIAS].contents == x[UALIAS].contents));

        std::vector<Test> tests = {
            {"serial distinct x, shared const p", SERIAL, ORIG, OTHER, false, false, false},
            {"serial distinct x, shared unwritten rw w", SERIAL, ORIG, OTHER, true, false, false},
            {"serial same x tracked", SERIAL, ORIG, ORIG, false, false, true},
            {"serial same x untracked", SERIAL, UNTR, UNTR, false, false, true},
            {"serial orig then tracked alias", SERIAL, ORIG, ALIAS, false, false, true},
            {"serial orig then untracked alias", SERIAL, ORIG, UALIAS, false, false, true},
            {"serial untracked alias then orig", SERIAL, UALIAS, ORIG, false, false, true},
            {"passes distinct x", PASSES, ORIG, OTHER, false, false, false},
            {"passes same x tracked", PASSES, ORIG, ORIG, false, false, true},
            {"passes same x untracked", PASSES, UNTR, UNTR, false, false, true},
            {"passes same x untracked + fence", PASSES, UNTR, UNTR, false, true, true},
            {"passes orig then untracked alias", PASSES, ORIG, UALIAS, false, false, true},
            {"passes orig then untracked alias + fence", PASSES, ORIG, UALIAS, false, true, true},
            {"passes untracked alias then orig + fence", PASSES, UALIAS, ORIG, false, true, true},
            {"cbs distinct x", CBS, ORIG, OTHER, false, false, false},
            {"cbs same x tracked", CBS, ORIG, ORIG, false, false, true},
            {"cbs same x untracked", CBS, UNTR, UNTR, false, false, true},
            {"cbs same x untracked + fence", CBS, UNTR, UNTR, false, true, true},
            {"cbs untracked alias then orig + fence", CBS, UALIAS, ORIG, false, true, true},
        };

        auto bindCommon = [&](id<MTLComputeCommandEncoder> e, id<MTLBuffer> xb, id<MTLBuffer> wb) {
            [e setBuffer:xb offset:0 atIndex:0];
            [e setBuffer:p offset:0 atIndex:1];
            [e setBuffer:wb offset:0 atIndex:2];
            [e setBytes:&iters length:4 atIndex:3];
        };
        auto one = MTLSizeMake(32, 1, 1);

        // One producer alone gives the spin time T.
        {
            std::vector<double> t;
            for (int k = 0; k < reps; k++) {
                id<MTLCommandBuffer> cb = [q commandBuffer];
                id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
                [e setComputePipelineState:prod];
                bindCommon(e, x[ORIG], w0);
                [e dispatchThreads:one threadsPerThreadgroup:one];
                [e endEncoding];
                [cb commit];
                [cb waitUntilCompleted];
                t.push_back((cb.GPUEndTime-cb.GPUStartTime)*1e6);
            }
            std::sort(t.begin(), t.end());
            printf("%-44s median %8.1f us  min %8.1f us\n", "one producer alone (T)", t[reps/2], t[0]);
        }

        for (int round = 0; round < 2; round++)
        for (const Test& test : tests) {
            std::vector<double> t;
            int stale = 0;
            for (int k = 0; k < reps; k++) {
                ((uint*) x[ORIG].contents)[0] = 0;
                ((uint*) x[OTHER].contents)[0] = 0;
                ((uint*) x[UNTR].contents)[0] = 0;
                ((uint*) r.contents)[0] = 99;
                id<MTLCommandBuffer> cb0 = [q commandBuffer];
                id<MTLCommandBuffer> cb = cb0;
                id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
                [e setComputePipelineState:prod];
                bindCommon(e, x[test.xa], w0);
                [e dispatchThreads:one threadsPerThreadgroup:one];
                if (test.split != SERIAL) {
                    if (test.fence)
                        [e updateFence:fence];
                    [e endEncoding];
                    if (test.split == CBS) {
                        [cb commit];
                        cb = [q commandBuffer];
                    }
                    e = [cb computeCommandEncoder];
                    if (test.fence)
                        [e waitForFence:fence];
                }
                [e setComputePipelineState:cons];
                bindCommon(e, x[test.xb], test.shareW ? w0 : w1);
                [e setBuffer:r offset:0 atIndex:4];
                [e dispatchThreads:one threadsPerThreadgroup:one];
                [e endEncoding];
                [cb commit];
                [cb waitUntilCompleted];
                t.push_back((cb.GPUEndTime-cb0.GPUStartTime)*1e6);
                if (((uint*) r.contents)[0] == 0)
                    stale++;
            }
            std::sort(t.begin(), t.end());
            printf("%-44s median %8.1f us  min %8.1f us", test.name.c_str(), t[reps/2], t[0]);
            if (test.check)
                printf("  stale %d/%d", stale, reps);
            printf("\n");
        }

        // Cost of one empty dispatch in a serial encoder, and of one pass (with and without a fence), as the slope over k.
        for (int mode = 0; mode < 3; mode++)
        for (int k : {1, 2, 8, 32}) {
            std::vector<double> t;
            for (int rep = 0; rep < reps; rep++) {
                id<MTLCommandBuffer> cb = [q commandBuffer];
                id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
                for (int i = 0; i < k; i++) {
                    if (i > 0 && mode > 0) {
                        if (mode == 2)
                            [e updateFence:fence];
                        [e endEncoding];
                        e = [cb computeCommandEncoder];
                        if (mode == 2)
                            [e waitForFence:fence];
                    }
                    [e setComputePipelineState:noop];
                    [e setBuffer:x[ORIG] offset:0 atIndex:0];
                    [e setBuffer:x[ALIAS] offset:0 atIndex:1];
                    [e setBytes:&iters length:4 atIndex:3];
                    [e dispatchThreads:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];
                }
                [e endEncoding];
                [cb commit];
                [cb waitUntilCompleted];
                t.push_back((cb.GPUEndTime-cb.GPUStartTime)*1e6);
            }
            std::sort(t.begin(), t.end());
            const char* what[] = {"noop dispatches in one serial encoder", "noop passes", "noop passes with fence"};
            printf("%-38s k=%2d median %7.1f us  min %7.1f us\n", what[mode], k, t[reps/2], t[0]);
        }
    }
    return 0;
}

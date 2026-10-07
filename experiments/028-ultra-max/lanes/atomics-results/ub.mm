// Microbenchmark: cost of force-accumulation primitives with a nonbonded-like write pattern.
// Each simdgroup walks tiles; lane l adds 3 components for atoms x*32+l and y*32+l.
// usage: ub [work]; the force buffer is 60 B/atom so force words fit, and the checksum covers the first 24 B/atom.
#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#include <algorithm>
#include <cstdio>
#include <random>
#include <vector>

static NSString* src = @R"(
#include <metal_stdlib>
using namespace metal;

inline void add_emul(device ulong* dest, ulong value) {
    device atomic_uint* word = (device atomic_uint*) dest;
    uint lower = (uint) value;
    uint upper = (uint) (value >> 32);
    uint oldLower = atomic_fetch_add_explicit(&word[0], lower, memory_order_relaxed);
    if (oldLower+lower < oldLower)
        upper++;
    if (upper != 0)
        atomic_fetch_add_explicit(&word[1], upper, memory_order_relaxed);
}
inline void add_lo(device ulong* dest, ulong value) {
    atomic_fetch_add_explicit((device atomic_uint*) dest, (uint) value, memory_order_relaxed);
}
inline void add_two_nr(device ulong* dest, ulong value) {
    device atomic_uint* word = (device atomic_uint*) dest;
    atomic_fetch_add_explicit(&word[0], (uint) value, memory_order_relaxed);
    atomic_fetch_add_explicit(&word[1], (uint) (value>>32), memory_order_relaxed);
}
inline void add_plain(device ulong* dest, ulong value) {
    *dest += value;
}
inline void add_float(device ulong* dest, ulong value) {
    atomic_fetch_add_explicit((device atomic_float*) dest, (float) (long) value, memory_order_relaxed);
}
inline long toFixed(float x) { return (long) (x * 0x100000000); }

#define BODY(ADD) \
    uint totalWarps = totalThreads/32; uint warp = gid/32; uint lane = gid&31; \
    for (uint t = warp; t < numTiles; t += totalWarps) { \
        int2 tile = tiles[t]; \
        float f = sin(float(t*32+lane)); \
        for (int k = 0; k < work; k++) f = fma(f, 0.999f, 0.001f); \
        uint a1 = tile.x*32+lane, a2 = tile.y*32+lane; \
        ADD(&force[a1], (ulong) toFixed(f)); \
        ADD(&force[a1+padded], (ulong) toFixed(-f)); \
        ADD(&force[a1+2*padded], (ulong) toFixed(0.5f*f)); \
        ADD(&force[a2], (ulong) toFixed(-f)); \
        ADD(&force[a2+padded], (ulong) toFixed(f)); \
        ADD(&force[a2+2*padded], (ulong) toFixed(-0.5f*f)); \
    }

#define ARGS device ulong* force [[buffer(0)]], device const int2* tiles [[buffer(1)]], constant uint& numTiles [[buffer(2)]], \
    constant uint& padded [[buffer(3)]], constant int& work [[buffer(4)]], uint gid [[thread_position_in_grid]], uint totalThreads [[threads_per_grid]]

kernel void k_emul(ARGS) { BODY(add_emul) }
kernel void k_lo(ARGS) { BODY(add_lo) }
kernel void k_two_nr(ARGS) { BODY(add_two_nr) }
kernel void k_plain(ARGS) { BODY(add_plain) }
kernel void k_float(ARGS) { BODY(add_float) }
inline void carry_hi(device ulong* dest, ulong value, uint oldLower) {
    uint lower = (uint) value;
    uint upper = (uint) (value >> 32);
    if (oldLower+lower < oldLower)
        upper++;
    if (upper != 0)
        atomic_fetch_add_explicit(((device atomic_uint*) dest)+1, upper, memory_order_relaxed);
}
inline uint add_lo_ret(device ulong* dest, ulong value) {
    return atomic_fetch_add_explicit((device atomic_uint*) dest, (uint) value, memory_order_relaxed);
}

// One returning atomic per add with the result kept live, as force words needs.
kernel void k_ret(ARGS) {
    uint totalWarps = totalThreads/32; uint warp = gid/32; uint lane = gid&31;
    uint acc = 0;
    for (uint t = warp; t < numTiles; t += totalWarps) {
        int2 tile = tiles[t];
        float f = sin(float(t*32+lane));
        for (int k = 0; k < work; k++) f = fma(f, 0.999f, 0.001f);
        uint a1 = tile.x*32+lane, a2 = tile.y*32+lane;
        acc ^= add_lo_ret(&force[a1], (ulong) toFixed(f));
        acc ^= add_lo_ret(&force[a1+padded], (ulong) toFixed(-f));
        acc ^= add_lo_ret(&force[a1+2*padded], (ulong) toFixed(0.5f*f));
        acc ^= add_lo_ret(&force[a2], (ulong) toFixed(-f));
        acc ^= add_lo_ret(&force[a2+padded], (ulong) toFixed(f));
        acc ^= add_lo_ret(&force[a2+2*padded], (ulong) toFixed(-0.5f*f));
    }
    if (acc == 0x9e3779b9u)
        force[0] = 1;
}

// Force words as in forceWords.metal: int words, 5 per component.
inline void add_words(device int* words, uint stride, uint index, float force) {
    int exponent = (int) ((as_type<uint>(force) >> 23) & 0xFF) - 127;
    int word = min(max(exponent+9, 0) >> 3, 4);
    int value = (int) (force*as_type<float>((uint) (127+32-8*word) << 23));
    while (value != 0) {
        device atomic_int* dest = (device atomic_int*) &words[word*stride+index];
        if (word == 4) {
            atomic_fetch_add_explicit(dest, value, memory_order_relaxed);
            return;
        }
        int old = atomic_fetch_add_explicit(dest, value, memory_order_relaxed);
        int sum = as_type<int>(as_type<uint>(old)+as_type<uint>(value));
        if (((old^sum) & (value^sum)) >= 0)
            return;
        value = (value > 0 ? 1<<24 : -(1<<24));
        word++;
    }
}
kernel void k_words(ARGS) {
    uint totalWarps = totalThreads/32; uint warp = gid/32; uint lane = gid&31;
    device int* words = (device int*) force;
    uint stride = 3*padded;
    for (uint t = warp; t < numTiles; t += totalWarps) {
        int2 tile = tiles[t];
        float f = sin(float(t*32+lane));
        for (int k = 0; k < work; k++) f = fma(f, 0.999f, 0.001f);
        uint a1 = tile.x*32+lane, a2 = tile.y*32+lane;
        add_words(words, stride, a1, f);
        add_words(words, stride, a1+padded, -f);
        add_words(words, stride, a1+2*padded, 0.5f*f);
        add_words(words, stride, a2, -f);
        add_words(words, stride, a2+padded, f);
        add_words(words, stride, a2+2*padded, -0.5f*f);
    }
}

kernel void k_batch(ARGS) {
    uint totalWarps = totalThreads/32; uint warp = gid/32; uint lane = gid&31;
    for (uint t = warp; t < numTiles; t += totalWarps) {
        int2 tile = tiles[t];
        float f = sin(float(t*32+lane));
        for (int k = 0; k < work; k++) f = fma(f, 0.999f, 0.001f);
        uint a1 = tile.x*32+lane, a2 = tile.y*32+lane;
        device ulong* d[6] = {&force[a1], &force[a1+padded], &force[a1+2*padded], &force[a2], &force[a2+padded], &force[a2+2*padded]};
        ulong v[6] = {(ulong) toFixed(f), (ulong) toFixed(-f), (ulong) toFixed(0.5f*f), (ulong) toFixed(-f), (ulong) toFixed(f), (ulong) toFixed(-0.5f*f)};
        uint o[6];
        for (int i = 0; i < 6; i++) o[i] = add_lo_ret(d[i], v[i]);
        for (int i = 0; i < 6; i++) carry_hi(d[i], v[i], o[i]);
    }
}

kernel void k_defer(ARGS) {
    uint totalWarps = totalThreads/32; uint warp = gid/32; uint lane = gid&31;
    device ulong* d[6];
    ulong v[6];
    uint o[6];
    bool pending = false;
    for (uint t = warp; t < numTiles; t += totalWarps) {
        int2 tile = tiles[t];
        float f = sin(float(t*32+lane));
        for (int k = 0; k < work; k++) f = fma(f, 0.999f, 0.001f);
        if (pending)
            for (int i = 0; i < 6; i++) carry_hi(d[i], v[i], o[i]);
        uint a1 = tile.x*32+lane, a2 = tile.y*32+lane;
        d[0] = &force[a1]; d[1] = &force[a1+padded]; d[2] = &force[a1+2*padded];
        d[3] = &force[a2]; d[4] = &force[a2+padded]; d[5] = &force[a2+2*padded];
        v[0] = (ulong) toFixed(f); v[1] = (ulong) toFixed(-f); v[2] = (ulong) toFixed(0.5f*f);
        v[3] = (ulong) toFixed(-f); v[4] = (ulong) toFixed(f); v[5] = (ulong) toFixed(-0.5f*f);
        for (int i = 0; i < 6; i++) o[i] = add_lo_ret(d[i], v[i]);
        pending = true;
    }
    if (pending)
        for (int i = 0; i < 6; i++) carry_hi(d[i], v[i], o[i]);
}
)";

static NSString* src64 = @R"(
#include <metal_stdlib>
using namespace metal;
kernel void k_u64(device atomic_ulong* force [[buffer(0)]], uint gid [[thread_position_in_grid]]) {
    atomic_fetch_add_explicit(&force[gid & 1023], (ulong) gid, memory_order_relaxed);
}
)";

int main(int argc, char** argv) {
    @autoreleasepool {
        int work = argc > 1 ? atoi(argv[1]) : 0;
        int reps = 30;
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        printf("device %s apple9=%d\n", dev.name.UTF8String, (int) [dev supportsFamily:MTLGPUFamilyApple9]);
        NSError* err = nil;
        id<MTLLibrary> lib64 = [dev newLibraryWithSource:src64 options:nil error:&err];
        printf("atomic_ulong fetch_add compiles: %s\n", lib64 ? "yes" : "no");
        err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&err];
        if (!lib) { printf("compile failed: %s\n", err.localizedDescription.UTF8String); return 1; }

        // apoa1-like: 2880 blocks, ~100 neighbor tiles per block, y within +-150 blocks.
        uint numBlocks = 2880, tilesPerBlock = 100;
        uint padded = numBlocks*32;
        std::mt19937 rng(1);
        std::vector<int> tiles;
        for (uint x = 0; x < numBlocks; x++)
            for (uint k = 0; k < tilesPerBlock; k++) {
                int y = std::min<int>(numBlocks-1, std::max<int>(0, (int) x + (int) (rng()%300) - 150));
                tiles.push_back(x); tiles.push_back(y);
            }
        uint numTiles = tiles.size()/2;
        id<MTLBuffer> force = [dev newBufferWithLength:5*3*padded*4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> tileBuf = [dev newBufferWithBytes:tiles.data() length:tiles.size()*4 options:MTLResourceStorageModeShared];
        id<MTLCommandQueue> q = [dev newCommandQueue];
        uint threads = 10*4*60*64;
        for (NSString* name in @[@"k_emul", @"k_ret", @"k_words", @"k_lo", @"k_plain", @"k_emul", @"k_ret", @"k_words", @"k_lo", @"k_plain"]) {
            id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:name] error:&err];
            std::vector<double> t;
            for (int r = 0; r < reps; r++) {
                id<MTLCommandBuffer> cb = [q commandBuffer];
                id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
                [blit fillBuffer:force range:NSMakeRange(0, force.length) value:0];
                [blit endEncoding];
                [cb commit];
                cb = [q commandBuffer];
                id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
                [enc setComputePipelineState:ps];
                [enc setBuffer:force offset:0 atIndex:0];
                [enc setBuffer:tileBuf offset:0 atIndex:1];
                [enc setBytes:&numTiles length:4 atIndex:2];
                [enc setBytes:&padded length:4 atIndex:3];
                [enc setBytes:&work length:4 atIndex:4];
                [enc dispatchThreads:MTLSizeMake(threads,1,1) threadsPerThreadgroup:MTLSizeMake(64,1,1)];
                [enc endEncoding];
                [cb commit];
                [cb waitUntilCompleted];
                t.push_back((cb.GPUEndTime-cb.GPUStartTime)*1e6);
            }
            unsigned long long sum = 0; const unsigned long long* fp = (const unsigned long long*) force.contents;
            for (uint i = 0; i < 3*padded; i++) sum = sum*31 + fp[i];
            std::sort(t.begin(), t.end());
            printf("checksum %llx  ", sum);
            printf("%-10s work=%d tiles=%u median %.1f us  min %.1f us\n", name.UTF8String, work, numTiles, t[reps/2], t[0]);
        }
    }
    return 0;
}

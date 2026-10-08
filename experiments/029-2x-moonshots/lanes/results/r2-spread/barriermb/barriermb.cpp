// Is memoryBarrier(resources:) in a concurrent compute encoder scoped to the listed resources (open question OQ1 in
// research/2026-09-25-metal-native-playbook.md), and do separate encoders on disjoint tracked buffers overlap?
// Chain A: one small long-running kernel on bufA. Chain B: 20 dependent full-GPU steps on bufB.
// Each arm is one command buffer, GPU time from GPUStartTime/GPUEndTime, median of reps.
// usage: barriermb <spinIters> <reps>
#define NS_PRIVATE_IMPLEMENTATION
#define MTL_PRIVATE_IMPLEMENTATION
#include <Foundation/Foundation.hpp>
#include <Metal/Metal.hpp>
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <vector>

static const char* SRC = R"(
#include <metal_stdlib>
using namespace metal;
kernel void spin(device float* a [[buffer(0)]], constant int& iters [[buffer(1)]], uint i [[thread_position_in_grid]]) {
    float x = a[i];
    for (int k = 0; k < iters; k++)
        x = fma(x, 0.9999f, 0.0001f);
    a[i] = x;
}
kernel void step(device float* b [[buffer(0)]], uint i [[thread_position_in_grid]]) {
    b[i] = b[i]*0.5f+1.0f;
}
)";

static const int NB = 1<<20, STEPS = 20;
MTL::Device* dev;
MTL::CommandQueue* queue;
MTL::ComputePipelineState *spinP, *stepP;
MTL::Buffer *bufA, *bufB;
int iters;

enum Barrier { NONE, RESOURCE, SCOPE };

static void encodeSpin(MTL::ComputeCommandEncoder* e) {
    e->setComputePipelineState(spinP);
    e->setBuffer(bufA, 0, 0);
    e->setBytes(&iters, sizeof(int), 1);
    e->dispatchThreads(MTL::Size(64, 1, 1), MTL::Size(64, 1, 1));
}

static void encodeStep(MTL::ComputeCommandEncoder* e) {
    e->setComputePipelineState(stepP);
    e->setBuffer(bufB, 0, 0);
    e->dispatchThreads(MTL::Size(NB, 1, 1), MTL::Size(256, 1, 1));
}

static void encodeChain(MTL::ComputeCommandEncoder* e, Barrier barrier) {
    for (int s = 0; s < STEPS; s++) {
        if (s > 0 && barrier == RESOURCE) {
            MTL::Resource* r[] = {bufB};
            e->memoryBarrier(r, 1);
        }
        if (s > 0 && barrier == SCOPE)
            e->memoryBarrier(MTL::BarrierScopeBuffers);
        encodeStep(e);
    }
}

static double run(std::function<void(MTL::CommandBuffer*)> body, int reps, bool check) {
    std::vector<double> t;
    for (int r = 0; r < reps+2; r++) {
        float* b = (float*) bufB->contents();
        for (int i = 0; i < NB; i++) b[i] = 0.0f;
        MTL::CommandBuffer* cb = queue->commandBuffer();
        body(cb);
        cb->commit();
        cb->waitUntilCompleted();
        if (r >= 2)
            t.push_back((cb->GPUEndTime()-cb->GPUStartTime())*1e6);
        if (check) {
            float expect = 0.0f;
            for (int s = 0; s < STEPS; s++) expect = expect*0.5f+1.0f;
            int bad = 0;
            for (int i = 0; i < NB; i++) bad += (b[i] != expect);
            if (bad) printf("    chain B wrong on %d of %d elements\n", bad, NB);
        }
    }
    std::sort(t.begin(), t.end());
    return t[t.size()/2];
}

int main(int argc, char** argv) {
    iters = atoi(argv[1]);
    int reps = atoi(argv[2]);
    NS::AutoreleasePool* pool = NS::AutoreleasePool::alloc()->init();
    dev = MTL::CreateSystemDefaultDevice();
    queue = dev->newCommandQueue();
    NS::Error* err = nullptr;
    MTL::Library* lib = dev->newLibrary(NS::String::string(SRC, NS::UTF8StringEncoding), nullptr, &err);
    if (!lib) { printf("compile failed\n"); return 1; }
    spinP = dev->newComputePipelineState(lib->newFunction(NS::String::string("spin", NS::UTF8StringEncoding)), &err);
    stepP = dev->newComputePipelineState(lib->newFunction(NS::String::string("step", NS::UTF8StringEncoding)), &err);
    bufA = dev->newBuffer(64*sizeof(float), MTL::ResourceStorageModeShared);
    bufB = dev->newBuffer(NB*sizeof(float), MTL::ResourceStorageModeShared);
    auto conc = [](MTL::CommandBuffer* cb) { return cb->computeCommandEncoder(MTL::DispatchTypeConcurrent); };
    auto ser = [](MTL::CommandBuffer* cb) { return cb->computeCommandEncoder(MTL::DispatchTypeSerial); };
    printf("%s, spin iters %d, chain B %d steps of %d threads, median of %d, us\n", dev->name()->utf8String(), iters, STEPS, NB, reps);
    double a = run([&](MTL::CommandBuffer* cb) { auto e = conc(cb); encodeSpin(e); e->endEncoding(); }, reps, false);
    printf("A alone                                        %9.1f\n", a);
    double bs = run([&](MTL::CommandBuffer* cb) { auto e = ser(cb); encodeChain(e, NONE); e->endEncoding(); }, reps, true);
    printf("B alone, serial encoder                        %9.1f\n", bs);
    double br = run([&](MTL::CommandBuffer* cb) { auto e = conc(cb); encodeChain(e, RESOURCE); e->endEncoding(); }, reps, true);
    printf("B alone, concurrent, resource barriers         %9.1f\n", br);
    double bsc = run([&](MTL::CommandBuffer* cb) { auto e = conc(cb); encodeChain(e, SCOPE); e->endEncoding(); }, reps, true);
    printf("B alone, concurrent, scope barriers            %9.1f\n", bsc);
    printf("A then B, one concurrent encoder, resource     %9.1f\n", run([&](MTL::CommandBuffer* cb) {
        auto e = conc(cb); encodeSpin(e); encodeChain(e, RESOURCE); e->endEncoding(); }, reps, true));
    printf("A then B, one concurrent encoder, scope        %9.1f\n", run([&](MTL::CommandBuffer* cb) {
        auto e = conc(cb); encodeSpin(e); encodeChain(e, SCOPE); e->endEncoding(); }, reps, true));
    printf("A then B, one serial encoder                   %9.1f\n", run([&](MTL::CommandBuffer* cb) {
        auto e = ser(cb); encodeSpin(e); encodeChain(e, NONE); e->endEncoding(); }, reps, true));
    printf("A encoder, then B in one serial encoder        %9.1f\n", run([&](MTL::CommandBuffer* cb) {
        auto e = ser(cb); encodeSpin(e); e->endEncoding(); auto f = ser(cb); encodeChain(f, NONE); f->endEncoding(); }, reps, true));
    printf("A encoder, then each B step its own encoder    %9.1f\n", run([&](MTL::CommandBuffer* cb) {
        auto e = ser(cb); encodeSpin(e); e->endEncoding();
        for (int s = 0; s < STEPS; s++) { auto f = ser(cb); encodeStep(f); f->endEncoding(); } }, reps, true));
    printf("B steps first then A, one concurrent, resource %9.1f\n", run([&](MTL::CommandBuffer* cb) {
        auto e = conc(cb); encodeStep(e); encodeSpin(e); encodeChain(e, RESOURCE); e->endEncoding(); }, reps, false));
    pool->release();
    return 0;
}

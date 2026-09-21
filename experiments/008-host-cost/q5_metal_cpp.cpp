#define NS_PRIVATE_IMPLEMENTATION
#define MTL_PRIVATE_IMPLEMENTATION
#include <Foundation/Foundation.hpp>
#include <Metal/Metal.hpp>
#include <iostream>
#include <vector>
#include <chrono>
#include <cmath>
#include <algorithm>

const char* kernelSrc = R"(
#include <metal_stdlib>
using namespace metal;
kernel void trivial_k(device float* out [[buffer(0)]],
                      device const float* in [[buffer(1)]],
                      uint id [[thread_position_in_grid]]) {
    out[id] = in[id] * 1.00001f + 0.0001f;
}
)";

double median(std::vector<double>& v) {
    if (v.empty()) return 0;
    std::sort(v.begin(), v.end());
    size_t n = v.size();
    if (n % 2 == 1) return v[n / 2];
    return (v[n / 2 - 1] + v[n / 2]) / 2.0;
}

double iqr(std::vector<double>& v) {
    if (v.size() < 4) return 0;
    std::sort(v.begin(), v.end());
    size_t n = v.size();
    return v[(3 * n) / 4] - v[n / 4];
}

int main(int argc, char** argv) {
    NS::AutoreleasePool* pool = NS::AutoreleasePool::alloc()->init();
    MTL::Device* device = MTL::CreateSystemDefaultDevice();
    if (!device) return 1;
    MTL::CommandQueue* queue = device->newCommandQueue();

    NS::Error* error = nullptr;
    NS::String* sourceStr = NS::String::string(kernelSrc, NS::UTF8StringEncoding);
    MTL::Library* library = device->newLibrary(sourceStr, nullptr, &error);
    NS::String* funcName = NS::String::string("trivial_k", NS::UTF8StringEncoding);
    MTL::Function* func = library->newFunction(funcName);
    MTL::ComputePipelineState* pso = device->newComputePipelineState(func, &error);
    func->release();
    library->release();

    const size_t count = 1024;
    MTL::Buffer* bufA = device->newBuffer(count * sizeof(float), MTL::ResourceStorageModeShared);
    MTL::Buffer* bufB = device->newBuffer(count * sizeof(float), MTL::ResourceStorageModeShared);
    float* ptrA = static_cast<float*>(bufA->contents());
    for (size_t i = 0; i < count; ++i) ptrA[i] = 1.0f;

    const int N = 10000;
    const int repeats = 20;
    std::vector<double> encodeUsPerDispatch;
    encodeUsPerDispatch.reserve(repeats);

    // Warmup
    {
        MTL::CommandBuffer* cb = queue->commandBuffer();
        MTL::ComputeCommandEncoder* enc = cb->computeCommandEncoder();
        enc->setComputePipelineState(pso);
        for (int i = 0; i < 100; ++i) {
            MTL::Buffer* inB = (i % 2 == 0) ? bufA : bufB;
            MTL::Buffer* outB = (i % 2 == 0) ? bufB : bufA;
            enc->setBuffer(outB, 0, 0);
            enc->setBuffer(inB, 0, 1);
            enc->dispatchThreads(MTL::Size(count, 1, 1), MTL::Size(256, 1, 1));
        }
        enc->endEncoding();
        cb->commit();
        cb->waitUntilCompleted();
    }

    for (int r = 0; r < repeats; ++r) {
        MTL::CommandBuffer* cb = queue->commandBuffer();
        MTL::ComputeCommandEncoder* enc = cb->computeCommandEncoder();
        enc->setComputePipelineState(pso);

        auto t0 = std::chrono::high_resolution_clock::now();
        for (int i = 0; i < N; ++i) {
            MTL::Buffer* inB = (i % 2 == 0) ? bufA : bufB;
            MTL::Buffer* outB = (i % 2 == 0) ? bufB : bufA;
            enc->setBuffer(outB, 0, 0);
            enc->setBuffer(inB, 0, 1);
            enc->dispatchThreads(MTL::Size(count, 1, 1), MTL::Size(256, 1, 1));
        }
        enc->endEncoding();
        auto t1 = std::chrono::high_resolution_clock::now();

        cb->commit();
        cb->waitUntilCompleted();

        double elapsedUs = std::chrono::duration<double, std::micro>(t1 - t0).count();
        encodeUsPerDispatch.push_back(elapsedUs / N);
    }

    // Verification
    float* finalPtr = static_cast<float*>((N % 2 == 0 ? bufA : bufB)->contents());
    bool pass = !std::isnan(finalPtr[0]) && finalPtr[0] > 1.0f;

    double med = median(encodeUsPerDispatch);
    double spread = iqr(encodeUsPerDispatch);

    std::cout << "{\"wrapper\": \"metal-cpp\", \"dispatches\": " << N 
              << ", \"median_us_per_dispatch\": " << med 
              << ", \"iqr_us_per_dispatch\": " << spread 
              << ", \"verification\": \"" << (pass ? "PASS" : "FAIL") << "\"}\n";

    bufA->release();
    bufB->release();
    pso->release();
    queue->release();
    device->release();
    pool->release();
    return pass ? 0 : 1;
}

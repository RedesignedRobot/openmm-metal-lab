#define VKFFT_BACKEND 5
#include <chrono>
static int FFT_BATCH = 1;
extern "C" void vkfft_metal_set_batch(int n) { FFT_BATCH = n; }
#include <cmath>
#include <iostream>
#include "vkFFT.h"

static VkFFTApplication appMetal = {};
static MTL::Device* devMetal = nullptr;
static MTL::CommandQueue* queueMetal = nullptr;
static bool appInitialized = false;

extern "C" int vkfft_metal_init(int nx, int ny, int nz, void* device, void* queue) {
    if (appInitialized) {
        deleteVkFFT(&appMetal);
        appInitialized = false;
    }
    devMetal = (MTL::Device*)device;
    queueMetal = (MTL::CommandQueue*)queue;

    VkFFTConfiguration config = {};
    config.FFTdim = 3;
    config.size[0] = nz;
    config.size[1] = ny;
    config.size[2] = nx;
    config.performR2C = 1;
    config.device = devMetal;
    config.queue = queueMetal;
    config.inverseReturnToInputBuffer = 1;
    config.isInputFormatted = 1;
    config.inputBufferStride[0] = nz;
    config.inputBufferStride[1] = ny * nz;
    config.inputBufferStride[2] = nx * ny * nz;

    VkFFTResult res = initializeVkFFT(&appMetal, config);
    if (res == VKFFT_SUCCESS) {
        appInitialized = true;
    }
    return (int)res;
}

extern "C" int vkfft_metal_forward(void* inBuf, void* outBuf, double* gpuTimeMs, double* wallTimeMs) {
    if (!appInitialized) return -1;
    MTL::CommandBuffer* cmdBuf = queueMetal->commandBuffer();
    MTL::ComputeCommandEncoder* enc = cmdBuf->computeCommandEncoder();
    VkFFTLaunchParams params = {};
    params.commandBuffer = cmdBuf;
    params.commandEncoder = enc;
    MTL::Buffer* in = (MTL::Buffer*)inBuf;
    MTL::Buffer* out = (MTL::Buffer*)outBuf;
    params.inputBuffer = &in;
    params.buffer = &out;

    auto t0 = std::chrono::steady_clock::now();
    // FFT_BATCH transforms per sync, so the sync round trip is amortised and the per-transform time is comparable across APIs.
    VkFFTResult res = VKFFT_SUCCESS;
    for (int b = 0; b < FFT_BATCH; b++) {
        res = VkFFTAppend(&appMetal, -1, &params);
        if (res != VKFFT_SUCCESS) return (int)res;
    }
    enc->endEncoding();
    cmdBuf->commit();
    cmdBuf->waitUntilCompleted();
    auto t1 = std::chrono::steady_clock::now();

    if (wallTimeMs) {
        *wallTimeMs = std::chrono::duration<double, std::milli>(t1 - t0).count() / FFT_BATCH;
    }
    if (gpuTimeMs) {
        *gpuTimeMs = (cmdBuf->GPUEndTime() - cmdBuf->GPUStartTime()) * 1000.0 / FFT_BATCH;
    }
    return 0;
}

extern "C" int vkfft_metal_inverse(void* inBuf, void* outBuf, double* gpuTimeMs, double* wallTimeMs) {
    if (!appInitialized) return -1;
    MTL::CommandBuffer* cmdBuf = queueMetal->commandBuffer();
    MTL::ComputeCommandEncoder* enc = cmdBuf->computeCommandEncoder();
    VkFFTLaunchParams params = {};
    params.commandBuffer = cmdBuf;
    params.commandEncoder = enc;
    MTL::Buffer* in = (MTL::Buffer*)inBuf;
    MTL::Buffer* out = (MTL::Buffer*)outBuf;
    params.inputBuffer = &out; // real buffer returned to inputBuffer
    params.buffer = &in;       // complex buffer in buffer

    auto t0 = std::chrono::steady_clock::now();
    // FFT_BATCH transforms per sync, so the sync round trip is amortised and the per-transform time is comparable across APIs.
    VkFFTResult res = VKFFT_SUCCESS;
    for (int b = 0; b < FFT_BATCH; b++) {
        res = VkFFTAppend(&appMetal, 1, &params);
        if (res != VKFFT_SUCCESS) return (int)res;
    }
    enc->endEncoding();
    cmdBuf->commit();
    cmdBuf->waitUntilCompleted();
    auto t1 = std::chrono::steady_clock::now();

    if (wallTimeMs) {
        *wallTimeMs = std::chrono::duration<double, std::milli>(t1 - t0).count() / FFT_BATCH;
    }
    if (gpuTimeMs) {
        *gpuTimeMs = (cmdBuf->GPUEndTime() - cmdBuf->GPUStartTime()) * 1000.0 / FFT_BATCH;
    }
    return 0;
}

extern "C" void vkfft_metal_free() {
    if (appInitialized) {
        deleteVkFFT(&appMetal);
        appInitialized = false;
    }
}

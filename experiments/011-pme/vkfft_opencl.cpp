#define VKFFT_BACKEND 3
#include <chrono>
static int FFT_BATCH = 1;
extern "C" void vkfft_opencl_set_batch(int n) { FFT_BATCH = n; }
#include <cmath>
#include <iostream>
#include <OpenCL/opencl.h>
#include "vkFFT.h"

static VkFFTApplication appOpenCL = {};
static cl_device_id devOpenCL = nullptr;
static cl_context ctxOpenCL = nullptr;
static cl_command_queue queueOpenCL = nullptr;
static bool appInitialized = false;

extern "C" int vkfft_opencl_init(int nx, int ny, int nz, void* device, void* context, void* queue) {
    if (appInitialized) {
        deleteVkFFT(&appOpenCL);
        appInitialized = false;
    }
    devOpenCL = (cl_device_id)device;
    ctxOpenCL = (cl_context)context;
    queueOpenCL = (cl_command_queue)queue;

    VkFFTConfiguration config = {};
    config.FFTdim = 3;
    config.size[0] = nz;
    config.size[1] = ny;
    config.size[2] = nx;
    config.performR2C = 1;
    config.device = &devOpenCL;
    config.context = &ctxOpenCL;
    config.inverseReturnToInputBuffer = 1;
    config.isInputFormatted = 1;
    config.inputBufferStride[0] = nz;
    config.inputBufferStride[1] = ny * nz;
    config.inputBufferStride[2] = nx * ny * nz;

    VkFFTResult res = initializeVkFFT(&appOpenCL, config);
    if (res == VKFFT_SUCCESS) {
        appInitialized = true;
    }
    return (int)res;
}

extern "C" int vkfft_opencl_forward(void* inBuf, void* outBuf, double* timeMs) {
    if (!appInitialized) return -1;
    VkFFTLaunchParams params = {};
    params.commandQueue = &queueOpenCL;
    cl_mem in = (cl_mem)inBuf;
    cl_mem out = (cl_mem)outBuf;
    params.inputBuffer = &in;
    params.buffer = &out;

    auto t0 = std::chrono::steady_clock::now();
    // FFT_BATCH transforms per sync, so the sync round trip is amortised and the per-transform time is comparable across APIs.
    VkFFTResult res = VKFFT_SUCCESS;
    for (int b = 0; b < FFT_BATCH; b++) {
        res = VkFFTAppend(&appOpenCL, -1, &params);
        if (res != VKFFT_SUCCESS) return (int)res;
    }
    clFinish(queueOpenCL);
    auto t1 = std::chrono::steady_clock::now();

    if (timeMs) {
        *timeMs = std::chrono::duration<double, std::milli>(t1 - t0).count() / FFT_BATCH;
    }
    return 0;
}

extern "C" int vkfft_opencl_inverse(void* inBuf, void* outBuf, double* timeMs) {
    if (!appInitialized) return -1;
    VkFFTLaunchParams params = {};
    params.commandQueue = &queueOpenCL;
    cl_mem in = (cl_mem)inBuf;
    cl_mem out = (cl_mem)outBuf;
    params.inputBuffer = &out; // real buffer returned to inputBuffer
    params.buffer = &in;       // complex buffer in buffer

    auto t0 = std::chrono::steady_clock::now();
    // FFT_BATCH transforms per sync, so the sync round trip is amortised and the per-transform time is comparable across APIs.
    VkFFTResult res = VKFFT_SUCCESS;
    for (int b = 0; b < FFT_BATCH; b++) {
        res = VkFFTAppend(&appOpenCL, 1, &params);
        if (res != VKFFT_SUCCESS) return (int)res;
    }
    clFinish(queueOpenCL);
    auto t1 = std::chrono::steady_clock::now();

    if (timeMs) {
        *timeMs = std::chrono::duration<double, std::milli>(t1 - t0).count() / FFT_BATCH;
    }
    return 0;
}

extern "C" void vkfft_opencl_free() {
    if (appInitialized) {
        deleteVkFFT(&appOpenCL);
        appInitialized = false;
    }
}

// Hypothesis (b), OpenCL side: the same conversions through Apple's OpenCL, built with the
// options OpenCLContext.cpp uses for OpenMM kernels.
#include <OpenCL/opencl.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static const char* src =
    "__kernel void conv(__global const float* in, __global long* fixedOut, __global long* longOut,\n"
    "                   __global ulong* ulongOut, __global int* intOut, __global long* satOut) {\n"
    "    int g = get_global_id(0);\n"
    "    float x = in[g];\n"
    "    fixedOut[g] = (long) (x * 0x100000000);\n"
    "    longOut[g] = (long) x;\n"
    "    ulongOut[g] = (ulong) x;\n"
    "    intOut[g] = (int) x;\n"
    "    satOut[g] = convert_long_sat(x * 0x100000000);\n"
    "}\n";

#define CHECK(e) do { cl_int _e = (e); if (_e != CL_SUCCESS) { fprintf(stderr, "%s -> %d\n", #e, _e); return 1; } } while (0)

int main(void) {
    float inputs[] = {
        0, 1, -1, 1.5f, -1.5f,
        1 << 30, 2147483520.0f, 2147483648.0f, -2147483648.0f, -2147483904.0f, 4294967040.0f, 4294967296.0f,
        4.0e9f, 1.0e10f, -1.0e10f, 4.611686e18f, 9.2233715e18f, 9.223372e18f, -9.223372e18f, -9.2233725e18f,
        1.8446743e19f, 3.0e19f, -3.0e19f, 1.0e20f, -1.0e20f, 1.0e26f, -1.0e26f, 3.4028235e38f, -3.4028235e38f,
        INFINITY, -INFINITY, NAN,
    };
    size_t n = sizeof(inputs) / sizeof(inputs[0]);
    cl_platform_id platform;
    cl_device_id device;
    cl_int err;
    CHECK(clGetPlatformIDs(1, &platform, NULL));
    CHECK(clGetDeviceIDs(platform, CL_DEVICE_TYPE_GPU, 1, &device, NULL));
    char name[256];
    clGetDeviceInfo(device, CL_DEVICE_NAME, sizeof(name), name, NULL);
    cl_context ctx = clCreateContext(NULL, 1, &device, NULL, NULL, &err); CHECK(err);
    cl_command_queue q = clCreateCommandQueue(ctx, device, 0, &err); CHECK(err);
    cl_program prog = clCreateProgramWithSource(ctx, 1, &src, NULL, &err); CHECK(err);
    if (clBuildProgram(prog, 1, &device, "-cl-mad-enable -cl-no-signed-zeros", NULL, NULL) != CL_SUCCESS) {
        char log[8192];
        clGetProgramBuildInfo(prog, device, CL_PROGRAM_BUILD_LOG, sizeof(log), log, NULL);
        fprintf(stderr, "%s\n", log);
        return 1;
    }
    cl_kernel k = clCreateKernel(prog, "conv", &err); CHECK(err);
    cl_mem in = clCreateBuffer(ctx, CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR, 4 * n, inputs, &err); CHECK(err);
    size_t sizes[5] = {8, 8, 8, 4, 8};
    cl_mem out[5];
    CHECK(clSetKernelArg(k, 0, sizeof(cl_mem), &in));
    for (int i = 0; i < 5; i++) {
        out[i] = clCreateBuffer(ctx, CL_MEM_WRITE_ONLY, sizes[i] * n, NULL, &err); CHECK(err);
        CHECK(clSetKernelArg(k, i + 1, sizeof(cl_mem), &out[i]));
    }
    CHECK(clEnqueueNDRangeKernel(q, k, 1, NULL, &n, NULL, 0, NULL, NULL));
    int64_t fixed[64], l[64], sat[64];
    uint64_t ul[64];
    int32_t i32[64];
    CHECK(clEnqueueReadBuffer(q, out[0], CL_TRUE, 0, 8 * n, fixed, 0, NULL, NULL));
    CHECK(clEnqueueReadBuffer(q, out[1], CL_TRUE, 0, 8 * n, l, 0, NULL, NULL));
    CHECK(clEnqueueReadBuffer(q, out[2], CL_TRUE, 0, 8 * n, ul, 0, NULL, NULL));
    CHECK(clEnqueueReadBuffer(q, out[3], CL_TRUE, 0, 4 * n, i32, 0, NULL, NULL));
    CHECK(clEnqueueReadBuffer(q, out[4], CL_TRUE, 0, 8 * n, sat, 0, NULL, NULL));
    printf("device %s (OpenCL)\n", name);
    printf("input(float bits)      input            (long)(x*2^32)       (long)x              (ulong)x             (int)x      convert_long_sat(x*2^32)\n");
    for (size_t i = 0; i < n; i++) {
        uint32_t bits;
        memcpy(&bits, &inputs[i], 4);
        printf("0x%08x  %-15.8g  0x%016llx  0x%016llx  0x%016llx  0x%08x  0x%016llx\n", bits, inputs[i],
               (unsigned long long) fixed[i], (unsigned long long) l[i], (unsigned long long) ul[i],
               (unsigned) i32[i], (unsigned long long) sat[i]);
    }
    return 0;
}

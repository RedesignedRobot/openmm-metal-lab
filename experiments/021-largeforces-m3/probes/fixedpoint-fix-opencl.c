// Candidate fix, OpenCL side: current realToFixedPoint, convert_long_sat, and explicit compares,
// over random float bit patterns, against a host reference that truncates toward zero and saturates.
#include <OpenCL/opencl.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char* src =
    "__kernel void conv(__global const float* in, __global long* cur, __global long* sat, __global long* saturated) {\n"
    "    int g = get_global_id(0);\n"
    "    float x = in[g];\n"
    "    cur[g] = (long) (x * 0x100000000);\n"
    "    sat[g] = convert_long_sat(x * 0x100000000);\n"
    "    float v = x * 0x100000000;\n"
    "    saturated[g] = v < -0x1p63f ? LONG_MIN : v >= 0x1p63f ? LONG_MAX : (long) v;\n"
    "}\n";

static int64_t reference(float x) {
    double v = (double) x * 4294967296.0;
    if (v >= 9223372036854775808.0) return INT64_MAX;
    if (v <= -9223372036854775808.0) return INT64_MIN;
    return (int64_t) v;
}

#define CHECK(e) do { cl_int _e = (e); if (_e != CL_SUCCESS) { fprintf(stderr, "%s -> %d\n", #e, _e); return 1; } } while (0)

int main(void) {
    size_t n = (1 << 20) + 1, nanIndex = n - 1;
    float* in = malloc(4 * n);
    int64_t* out[3];
    srandom(5434);
    for (size_t i = 0; i < nanIndex; i++) {
        uint32_t bits;
        do { bits = ((uint32_t) random() << 16) ^ (uint32_t) random(); memcpy(&in[i], &bits, 4); } while (isnan(in[i]));
    }
    in[0] = INFINITY; in[1] = -INFINITY; in[2] = 0x1p31f; in[3] = -0x1p31f;
    in[nanIndex] = NAN;
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
    CHECK(clBuildProgram(prog, 1, &device, "-cl-mad-enable -cl-no-signed-zeros", NULL, NULL));
    cl_kernel k = clCreateKernel(prog, "conv", &err); CHECK(err);
    cl_mem inBuf = clCreateBuffer(ctx, CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR, 4 * n, in, &err); CHECK(err);
    CHECK(clSetKernelArg(k, 0, sizeof(cl_mem), &inBuf));
    cl_mem outBuf[3];
    for (int i = 0; i < 3; i++) {
        outBuf[i] = clCreateBuffer(ctx, CL_MEM_WRITE_ONLY, 8 * n, NULL, &err); CHECK(err);
        CHECK(clSetKernelArg(k, i + 1, sizeof(cl_mem), &outBuf[i]));
    }
    CHECK(clEnqueueNDRangeKernel(q, k, 1, NULL, &n, NULL, 0, NULL, NULL));
    const char* names[3] = {"current (long)(x*2^32)", "convert_long_sat", "saturated"};
    printf("device %s (OpenCL), %zu non-NaN inputs\n", name, n - 1);
    for (int j = 0; j < 3; j++) {
        out[j] = malloc(8 * n);
        CHECK(clEnqueueReadBuffer(q, outBuf[j], CL_TRUE, 0, 8 * n, out[j], 0, NULL, NULL));
        size_t bad = 0, inRangeBad = 0;
        for (size_t i = 0; i < nanIndex; i++) {
            if (out[j][i] != reference(in[i])) {
                bad++;
                if (fabs((double) in[i] * 4294967296.0) < 9223372036854775808.0) inRangeBad++;
            }
        }
        printf("%-24s %zu disagree with saturating reference (%zu of them in range), NaN -> 0x%016llx\n", names[j], bad, inRangeBad, (unsigned long long) out[j][nanIndex]);
    }
    return 0;
}

// verify-e4: OpenCL float -> long conversions, same inputs idea as probe.swift.
#define CL_SILENCE_DEPRECATION
#include <OpenCL/opencl.h>
#include <stdio.h>
#include <math.h>
#include <float.h>
static const char* src =
"typedef float real;\n"
"inline long realToFixedPoint(real x) { return (long) (x * 0x100000000); }\n"
"inline long fixedCl(real x) { return convert_long_sat(x * 0x100000000); }\n"
"__kernel void probe(__global const float* in, __global ulong* out) {\n"
"  int i = get_global_id(0); float v = in[i];\n"
"  out[3*i] = (ulong) realToFixedPoint(v); out[3*i+1] = (ulong) fixedCl(v); out[3*i+2] = (ulong) (long) v;\n"
"}\n";
int main(void) {
    float in[] = {0, -0.0f, 1, -2.5f, 2147483520.0f, 2147483648.0f, -2147483648.0f, -2147483904.0f, 1e10f, -1e10f,
                  36028797018963968.0f, 9223372036854775808.0f, -9223372036854775808.0f, 1e19f, 2.1837e22f, -3.877e26f, 4e26f,
                  FLT_MAX, -FLT_MAX, INFINITY, -INFINITY, NAN};
    const char* names[] = {"0","-0","1","-2.5","2^31-128","2^31","-2^31","-(2^31+256)","1e10","-1e10","2^55","2^63","-2^63","1e19",
                           "2.1837e22","-3.877e26","4e26","FLT_MAX","-FLT_MAX","+inf","-inf","NaN"};
    enum { N = sizeof(in) / sizeof(in[0]) };
    cl_platform_id p; cl_device_id d; cl_int e; char name[256];
    clGetPlatformIDs(1, &p, NULL); clGetDeviceIDs(p, CL_DEVICE_TYPE_GPU, 1, &d, NULL);
    clGetDeviceInfo(d, CL_DEVICE_NAME, sizeof(name), name, NULL);
    cl_context c = clCreateContext(NULL, 1, &d, NULL, NULL, &e);
    cl_command_queue q = clCreateCommandQueue(c, d, 0, &e);
    cl_program prog = clCreateProgramWithSource(c, 1, &src, NULL, &e);
    if (clBuildProgram(prog, 1, &d, "-cl-mad-enable -cl-no-signed-zeros", NULL, NULL) != CL_SUCCESS) {
        char log[8192]; clGetProgramBuildInfo(prog, d, CL_PROGRAM_BUILD_LOG, sizeof(log), log, NULL); printf("BUILD FAILED\n%s\n", log); return 1;
    }
    cl_kernel k = clCreateKernel(prog, "probe", &e);
    cl_mem bi = clCreateBuffer(c, CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR, sizeof(in), in, &e);
    cl_mem bo = clCreateBuffer(c, CL_MEM_WRITE_ONLY, 3 * N * 8, NULL, &e);
    clSetKernelArg(k, 0, sizeof(bi), &bi); clSetKernelArg(k, 1, sizeof(bo), &bo);
    size_t g = N; clEnqueueNDRangeKernel(q, k, 1, NULL, &g, NULL, 0, NULL, NULL);
    unsigned long long out[3 * N]; clEnqueueReadBuffer(q, bo, CL_TRUE, 0, sizeof(out), out, 0, NULL, NULL);
    printf("device %s (OpenCL)\n%-12s %-18s %-18s %-18s\n", name, "x", "(long)(x*2^32)", "convert_long_sat", "(long)x");
    for (int i = 0; i < N; i++) printf("%-12s %016llx   %016llx   %016llx\n", names[i], out[3*i], out[3*i+1], out[3*i+2]);
    return 0;
}

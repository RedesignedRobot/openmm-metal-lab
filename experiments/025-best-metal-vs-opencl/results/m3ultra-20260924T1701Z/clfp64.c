/* Prints each OpenCL GPU device's name, whether it lists cl_khr_fp64, and its double FP config.
   OpenMM's OpenCL platform needs cl_khr_fp64 (or cl_amd_fp64) for mixed and double precision.
   build: cc -o clfp64 clfp64.c -framework OpenCL */
#define CL_SILENCE_DEPRECATION
#include <OpenCL/opencl.h>
#include <stdio.h>
#include <string.h>

int main(void) {
    cl_platform_id platforms[8];
    cl_uint numPlatforms = 0;
    clGetPlatformIDs(8, platforms, &numPlatforms);
    for (cl_uint p = 0; p < numPlatforms; p++) {
        cl_device_id devices[8];
        cl_uint numDevices = 0;
        if (clGetDeviceIDs(platforms[p], CL_DEVICE_TYPE_ALL, 8, devices, &numDevices) != CL_SUCCESS)
            continue;
        for (cl_uint d = 0; d < numDevices; d++) {
            char name[256], version[256], extensions[8192];
            cl_device_fp_config fp64 = 0;
            clGetDeviceInfo(devices[d], CL_DEVICE_NAME, sizeof(name), name, NULL);
            clGetDeviceInfo(devices[d], CL_DEVICE_VERSION, sizeof(version), version, NULL);
            clGetDeviceInfo(devices[d], CL_DEVICE_EXTENSIONS, sizeof(extensions), extensions, NULL);
            clGetDeviceInfo(devices[d], CL_DEVICE_DOUBLE_FP_CONFIG, sizeof(fp64), &fp64, NULL);
            printf("platform %u device %u: %s, %s\n", p, d, name, version);
            printf("  cl_khr_fp64 %s, cl_amd_fp64 %s, CL_DEVICE_DOUBLE_FP_CONFIG 0x%llx\n",
                   strstr(extensions, "cl_khr_fp64") ? "listed" : "absent",
                   strstr(extensions, "cl_amd_fp64") ? "listed" : "absent", (unsigned long long) fp64);
            printf("  extensions: %s\n", extensions);
        }
    }
    return 0;
}

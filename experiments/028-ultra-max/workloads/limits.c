#include <OpenCL/opencl.h>
#include <stdio.h>
int main(void) {
    cl_platform_id p; cl_device_id d; cl_ulong alloc, global; char name[256];
    clGetPlatformIDs(1, &p, NULL);
    clGetDeviceIDs(p, CL_DEVICE_TYPE_GPU, 1, &d, NULL);
    clGetDeviceInfo(d, CL_DEVICE_NAME, sizeof name, name, NULL);
    clGetDeviceInfo(d, CL_DEVICE_MAX_MEM_ALLOC_SIZE, sizeof alloc, &alloc, NULL);
    clGetDeviceInfo(d, CL_DEVICE_GLOBAL_MEM_SIZE, sizeof global, &global, NULL);
    printf("OpenCL %s CL_DEVICE_MAX_MEM_ALLOC_SIZE %llu (%.2f GiB) CL_DEVICE_GLOBAL_MEM_SIZE %llu (%.2f GiB)\n", name, alloc, alloc/1073741824.0, global, global/1073741824.0);
    return 0;
}

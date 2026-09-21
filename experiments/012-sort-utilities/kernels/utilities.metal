#include <metal_stdlib>
using namespace metal;

kernel void clearBuffer(
    device int* buffer [[buffer(0)]],
    constant int& size [[buffer(1)]],
    uint globalId [[thread_position_in_grid]],
    uint globalSize [[threads_per_grid]]
) {
    int index = (int)globalId;
    device int4* buffer4 = (device int4*) buffer;
    int sizeDiv4 = size / 4;
#ifdef MUTATION_CLEAR
    int4 clearVal = int4(1);
#else
    int4 clearVal = int4(0);
#endif
    while (index < sizeDiv4) {
        buffer4[index] = clearVal;
        index += (int)globalSize;
    }
    if (globalId == 0) {
        for (int i = sizeDiv4 * 4; i < size; i++)
            buffer[i] = clearVal.x;
    }
}

kernel void clearTwoBuffers(
    device int* buffer1 [[buffer(0)]],
    constant int& size1 [[buffer(1)]],
    device int* buffer2 [[buffer(2)]],
    constant int& size2 [[buffer(3)]],
    uint globalId [[thread_position_in_grid]],
    uint globalSize [[threads_per_grid]]
) {
#ifdef MUTATION_CLEAR
    int4 clearVal = int4(1);
#else
    int4 clearVal = int4(0);
#endif
    int index = (int)globalId;
    device int4* b1_4 = (device int4*) buffer1;
    int s1Div4 = size1 / 4;
    while (index < s1Div4) {
        b1_4[index] = clearVal;
        index += (int)globalSize;
    }
    if (globalId == 0) {
        for (int i = s1Div4 * 4; i < size1; i++)
            buffer1[i] = clearVal.x;
    }

    index = (int)globalId;
    device int4* b2_4 = (device int4*) buffer2;
    int s2Div4 = size2 / 4;
    while (index < s2Div4) {
        b2_4[index] = clearVal;
        index += (int)globalSize;
    }
    if (globalId == 0) {
        for (int i = s2Div4 * 4; i < size2; i++)
            buffer2[i] = clearVal.x;
    }
}

kernel void reduceFloat4Buffer(
    device float4* buffer [[buffer(0)]],
    device long* longBuffer [[buffer(1)]],
    constant int& bufferSize [[buffer(2)]],
    constant int& numBuffers [[buffer(3)]],
    uint globalId [[thread_position_in_grid]],
    uint globalSize [[threads_per_grid]]
) {
    int index = (int)globalId;
    int totalSize = bufferSize * numBuffers;
#ifdef MUTATION_REDUCE
    totalSize -= bufferSize; // Drop the final buffer from summation
#endif
    while (index < bufferSize) {
        float4 sum = buffer[index];
        for (int i = index + bufferSize; i < totalSize; i += bufferSize)
            sum += buffer[i];
        buffer[index] = sum;
        longBuffer[index] = (long)(sum.x * 4294967296.0f);
        longBuffer[index + bufferSize] = (long)(sum.y * 4294967296.0f);
        longBuffer[index + 2 * bufferSize] = (long)(sum.z * 4294967296.0f);
        index += (int)globalSize;
    }
}

kernel void reduceForces(
    device long* longBuffer [[buffer(0)]],
    device float4* buffer [[buffer(1)]],
    constant int& bufferSize [[buffer(2)]],
    constant int& numBuffers [[buffer(3)]],
    uint globalId [[thread_position_in_grid]],
    uint globalSize [[threads_per_grid]]
) {
    int totalSize = bufferSize * numBuffers;
    float scale = 1.0f / 4294967296.0f;
    for (int index = (int)globalId; index < bufferSize; index += (int)globalSize) {
        float4 sum = float4(scale * (float)longBuffer[index],
                            scale * (float)longBuffer[index + bufferSize],
                            scale * (float)longBuffer[index + 2 * bufferSize],
                            0.0f);
        for (int i = index; i < totalSize; i += bufferSize)
            sum += buffer[i];
#ifdef MUTATION_REDUCE
        sum.x *= 1.05f;
#endif
        buffer[index] = sum;
        longBuffer[index] = (long)(sum.x * 4294967296.0f);
        longBuffer[index + bufferSize] = (long)(sum.y * 4294967296.0f);
        longBuffer[index + 2 * bufferSize] = (long)(sum.z * 4294967296.0f);
    }
}

kernel void reduceEnergy(
    device const float* energyBuffer [[buffer(0)]],
    device float* result [[buffer(1)]],
    constant int& bufferSize [[buffer(2)]],
    constant int& workGroupSize [[buffer(3)]],
    uint localId [[thread_position_in_threadgroup]],
    uint globalId [[thread_position_in_grid]],
    uint globalSize [[threads_per_grid]],
    uint groupId [[threadgroup_position_in_grid]]
) {
    threadgroup float tempBuffer[512];
    float sum = 0.0f;
    for (int index = (int)globalId; index < bufferSize; index += (int)globalSize)
        sum += energyBuffer[index];
#ifdef MUTATION_REDUCE
    sum *= 1.05f;
#endif
    tempBuffer[localId] = sum;
    for (int i = 1; i < workGroupSize; i *= 2) {
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if ((localId % (i * 2) == 0) && ((int)localId + i < workGroupSize))
            tempBuffer[localId] += tempBuffer[localId + i];
    }
    if (localId == 0)
        result[groupId] = tempBuffer[0];
}

kernel void setCharges(
    device const float* charges [[buffer(0)]],
    device float4* posq [[buffer(1)]],
    device const int* atomOrder [[buffer(2)]],
    constant int& numAtoms [[buffer(3)]],
    uint globalId [[thread_position_in_grid]],
    uint globalSize [[threads_per_grid]]
) {
    for (int i = (int)globalId; i < numAtoms; i += (int)globalSize) {
#ifdef MUTATION_CHARGES
        posq[i].w = -charges[atomOrder[i]];
#else
        posq[i].w = charges[atomOrder[i]];
#endif
    }
}

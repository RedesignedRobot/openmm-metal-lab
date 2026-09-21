#include <metal_stdlib>
using namespace metal;

#ifndef DATA_TYPE
#define DATA_TYPE uint
#endif

#ifndef KEY_TYPE
#define KEY_TYPE uint
#endif

#ifndef MAX_VALUE
#define MAX_VALUE 0xFFFFFFFFu
#endif

inline KEY_TYPE getValue(DATA_TYPE value) {
    return value;
}

// Bitonic sort for a short list within a single threadgroup
kernel void sortShortList(
    device DATA_TYPE* data [[buffer(0)]],
    constant uint& length [[buffer(1)]],
    threadgroup DATA_TYPE* dataBuffer [[threadgroup(0)]],
    uint localId [[thread_position_in_threadgroup]],
    uint localSize [[threads_per_threadgroup]]
) {
    for (int index = localId; index < (int)length; index += localSize)
        dataBuffer[index] = data[index];
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (unsigned int k = 2; k < 2 * length; k *= 2) {
        for (unsigned int j = k / 2; j > 0; j /= 2) {
            for (unsigned int i = localId; i < length; i += localSize) {
                int ixj = i ^ j;
                if (ixj > (int)i && ixj < (int)length) {
                    DATA_TYPE value1 = dataBuffer[i];
                    DATA_TYPE value2 = dataBuffer[ixj];
                    bool ascending = ((i & k) == 0);
                    for (unsigned int mask = k * 2; mask < 2 * length; mask *= 2)
                        ascending = ((i & mask) == 0 ? !ascending : ascending);
                    KEY_TYPE lowKey  = (ascending ? getValue(value1) : getValue(value2));
                    KEY_TYPE highKey = (ascending ? getValue(value2) : getValue(value1));
                    if (lowKey > highKey) {
                        dataBuffer[i] = value2;
                        dataBuffer[ixj] = value1;
                    }
                }
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }
    }

    for (int index = localId; index < (int)length; index += localSize)
        data[index] = dataBuffer[index];
}

// Calculate minimum and maximum data values
kernel void computeRange(
    device const DATA_TYPE* data [[buffer(0)]],
    constant uint& length [[buffer(1)]],
    device KEY_TYPE* range [[buffer(2)]],
    constant uint& numBuckets [[buffer(3)]],
    device uint* bucketOffset [[buffer(4)]],
    threadgroup KEY_TYPE* minBuffer [[threadgroup(0)]],
    threadgroup KEY_TYPE* maxBuffer [[threadgroup(1)]],
    uint localId [[thread_position_in_threadgroup]],
    uint localSize [[threads_per_threadgroup]]
) {
#if UNIFORM
    KEY_TYPE minimum = 0xFFFFFFFFu;
    KEY_TYPE maximum = 0;

    for (uint index = localId; index < length; index += localSize) {
        KEY_TYPE value = getValue(data[index]);
        minimum = min(minimum, value);
        maximum = max(maximum, value);
    }

    minBuffer[localId] = minimum;
    maxBuffer[localId] = maximum;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint step = 1; step < localSize; step *= 2) {
        if (localId + step < localSize && localId % (2 * step) == 0) {
            minBuffer[localId] = min(minBuffer[localId], minBuffer[localId + step]);
            maxBuffer[localId] = max(maxBuffer[localId], maxBuffer[localId + step]);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (localId == 0) {
        range[0] = minBuffer[0];
        range[1] = maxBuffer[0];
    }
#endif

    for (uint index = localId; index < numBuckets; index += localSize)
        bucketOffset[index] = 0;
}

// Assign elements to buckets: uniform distribution
kernel void assignElementsToBuckets(
    device const DATA_TYPE* data [[buffer(0)]],
    constant uint& length [[buffer(1)]],
    constant uint& numBuckets [[buffer(2)]],
    device const KEY_TYPE* range [[buffer(3)]],
    device uint* bucketOffset [[buffer(4)]],
    device uint* bucketOfElement [[buffer(5)]],
    device uint* offsetInBucket [[buffer(6)]],
    uint globalId [[thread_position_in_grid]],
    uint globalSize [[threads_per_grid]]
) {
    float minValue = (float) (range[0]);
    float maxValue = (float) (range[1]);
    float bucketWidth = (maxValue - minValue) / numBuckets;
    for (uint index = globalId; index < length; index += globalSize) {
        float key = (float) getValue(data[index]);
        uint bucketIndex = min((uint) ((key - minValue) / bucketWidth), numBuckets - 1);
        offsetInBucket[index] = atomic_fetch_add_explicit((device atomic_uint*)&bucketOffset[bucketIndex], 1, memory_order_relaxed);
        bucketOfElement[index] = bucketIndex;
    }
}

// Assign elements to buckets: non-uniform distribution
kernel void assignElementsToBuckets2(
    device const DATA_TYPE* data [[buffer(0)]],
    constant uint& length [[buffer(1)]],
    constant uint& numBuckets [[buffer(2)]],
    device const KEY_TYPE* range [[buffer(3)]],
    device uint* bucketOffset [[buffer(4)]],
    device uint* bucketOfElement [[buffer(5)]],
    device uint* offsetInBucket [[buffer(6)]],
    uint localId [[thread_position_in_threadgroup]],
    uint localSize [[threads_per_threadgroup]],
    uint globalId [[thread_position_in_grid]],
    uint globalSize [[threads_per_grid]]
) {
    threadgroup KEY_TYPE elements[64];
    if (localId < 64) {
        int index = (int) (localId * length / 64.0f);
        elements[localId] = getValue(data[index]);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (unsigned int k = 2; k <= 64; k *= 2) {
        for (unsigned int j = k / 2; j > 0; j /= 2) {
            if (localId < 64) {
                int ixj = localId ^ j;
                if (ixj > localId) {
                    KEY_TYPE value1 = elements[localId];
                    KEY_TYPE value2 = elements[ixj];
                    bool ascending = (localId & k) == 0;
                    KEY_TYPE lowKey = (ascending ? value1 : value2);
                    KEY_TYPE highKey = (ascending ? value2 : value1);
                    if (lowKey > highKey) {
                        elements[localId] = value2;
                        elements[ixj] = value1;
                    }
                }
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }
    }

    threadgroup float segmentLowerBound[9];
    threadgroup float segmentBaseIndex[9];
    threadgroup float segmentIndexScale[9];
    if (localId == 0) {
        segmentLowerBound[0] = (float)elements[0] - 0.2f * ((float)elements[5] - (float)elements[0]);
        segmentLowerBound[1] = (float)elements[5];
        segmentLowerBound[2] = (float)elements[10];
        segmentLowerBound[3] = (float)elements[20];
        segmentLowerBound[4] = (float)elements[30];
        segmentLowerBound[5] = (float)elements[40];
        segmentLowerBound[6] = (float)elements[50];
        segmentLowerBound[7] = (float)elements[60];
        segmentLowerBound[8] = (float)elements[63] + 0.2f * ((float)elements[63] - (float)elements[58]);
        segmentBaseIndex[0] = numBuckets / 16.0f;
        segmentBaseIndex[1] = 3.0f * numBuckets / 16.0f;
        segmentBaseIndex[2] = 5.0f * numBuckets / 16.0f;
        segmentBaseIndex[3] = 7.0f * numBuckets / 16.0f;
        segmentBaseIndex[4] = 9.0f * numBuckets / 16.0f;
        segmentBaseIndex[5] = 11.0f * numBuckets / 16.0f;
        segmentBaseIndex[6] = 13.0f * numBuckets / 16.0f;
        segmentBaseIndex[7] = 15.0f * numBuckets / 16.0f;
        segmentBaseIndex[8] = (float)numBuckets;
        for (int i = 0; i < 8; i++) {
            if (segmentLowerBound[i + 1] == segmentLowerBound[i])
                segmentIndexScale[i] = 0.0f;
            else
                segmentIndexScale[i] = (segmentBaseIndex[i + 1] - segmentBaseIndex[i]) / (segmentLowerBound[i + 1] - segmentLowerBound[i]);
        }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (unsigned int index = globalId; index < length; index += globalSize) {
        float key = (float) getValue(data[index]);
        int segment;
        for (segment = 0; segment < 7 && key > segmentLowerBound[segment + 1]; segment++)
            ;
        unsigned int bucketIndex = (unsigned int)(segmentBaseIndex[segment] + (key - segmentLowerBound[segment]) * segmentIndexScale[segment]);
        bucketIndex = min(max((uint)0, bucketIndex), numBuckets - 1);
#ifdef MUTATION_SORT
        // Mutation: shift bucket index by 1 modulo numBuckets
        bucketIndex = (bucketIndex + 1) % numBuckets;
#endif
        offsetInBucket[index] = atomic_fetch_add_explicit((device atomic_uint*)&bucketOffset[bucketIndex], 1, memory_order_relaxed);
        bucketOfElement[index] = bucketIndex;
    }
}

// Compute bucket start positions via parallel prefix sum
kernel void computeBucketPositions(
    constant uint& numBuckets [[buffer(0)]],
    device uint* bucketOffset [[buffer(1)]],
    threadgroup uint* buffer [[threadgroup(0)]],
    uint localId [[thread_position_in_threadgroup]],
    uint localSize [[threads_per_threadgroup]]
) {
    uint globalOffset = 0;
    for (uint startBucket = 0; startBucket < numBuckets; startBucket += localSize) {
        uint globalIndex = startBucket + localId;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        buffer[localId] = (globalIndex < numBuckets ? bucketOffset[globalIndex] : 0);
        threadgroup_barrier(mem_flags::mem_threadgroup);

        for (uint step = 1; step < localSize; step *= 2) {
            uint add = (localId >= step ? buffer[localId - step] : 0);
            threadgroup_barrier(mem_flags::mem_threadgroup);
            buffer[localId] += add;
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }

        if (globalIndex < numBuckets)
            bucketOffset[globalIndex] = buffer[localId] + globalOffset;
        globalOffset += buffer[localSize - 1];
    }
}

// Copy input data into assigned buckets
kernel void copyDataToBuckets(
    device const DATA_TYPE* data [[buffer(0)]],
    device DATA_TYPE* buckets [[buffer(1)]],
    constant uint& length [[buffer(2)]],
    device const uint* bucketOffset [[buffer(3)]],
    device const uint* bucketOfElement [[buffer(4)]],
    device const uint* offsetInBucket [[buffer(5)]],
    uint globalId [[thread_position_in_grid]],
    uint globalSize [[threads_per_grid]]
) {
    for (uint index = globalId; index < length; index += globalSize) {
        DATA_TYPE element = data[index];
        uint bucketIndex = bucketOfElement[index];
        uint offset = (bucketIndex == 0 ? 0 : bucketOffset[bucketIndex - 1]);
        buckets[offset + offsetInBucket[index]] = element;
    }
}

// Sort elements in each bucket
kernel void sortBuckets(
    device DATA_TYPE* data [[buffer(0)]],
    device const DATA_TYPE* buckets [[buffer(1)]],
    constant uint& numBuckets [[buffer(2)]],
    device const uint* bucketOffset [[buffer(3)]],
    threadgroup DATA_TYPE* buffer [[threadgroup(0)]],
    uint localId [[thread_position_in_threadgroup]],
    uint localSize [[threads_per_threadgroup]],
    uint groupId [[threadgroup_position_in_grid]],
    uint numGroups [[threadgroups_per_grid]]
) {
    for (int index = groupId; index < (int)numBuckets; index += numGroups) {
        int startIndex = (index == 0 ? 0 : bucketOffset[index - 1]);
        int endIndex = bucketOffset[index];
        int length = endIndex - startIndex;
        if (length <= (int)localSize) {
            if (localId < (uint)length)
                buffer[localId] = buckets[startIndex + localId];
            else
                buffer[localId] = MAX_VALUE;
            threadgroup_barrier(mem_flags::mem_threadgroup);

            for (int k = 2; k <= (int)localSize; k *= 2) {
                for (int j = k / 2; j > 0; j /= 2) {
                    int ixj = localId ^ j;
                    if (ixj > (int)localId) {
                        DATA_TYPE value1 = buffer[localId];
                        DATA_TYPE value2 = buffer[ixj];
                        bool ascending = ((localId & k) == 0);
                        KEY_TYPE lowKey = (ascending ? getValue(value1) : getValue(value2));
                        KEY_TYPE highKey = (ascending ? getValue(value2) : getValue(value1));
                        if (lowKey > highKey) {
                            buffer[localId] = value2;
                            buffer[ixj] = value1;
                        }
                    }
                    threadgroup_barrier(mem_flags::mem_threadgroup);
                }
            }

            if (localId < (uint)length)
                data[startIndex + localId] = buffer[localId];
        }
        else {
            for (int i = localId; i < length; i += localSize)
                data[startIndex + i] = buckets[startIndex + i];
            threadgroup_barrier(mem_flags::mem_device);

            for (int k = 2; k < 2 * length; k *= 2) {
                for (int j = k / 2; j > 0; j /= 2) {
                    for (int i = localId; i < length; i += localSize) {
                        int ixj = i ^ j;
                        if (ixj > i && ixj < length) {
                            DATA_TYPE value1 = data[startIndex + i];
                            DATA_TYPE value2 = data[startIndex + ixj];
                            bool ascending = ((i & k) == 0);
                            for (int mask = k * 2; mask < 2 * length; mask *= 2)
                                ascending = ((i & mask) == 0 ? !ascending : ascending);
                            KEY_TYPE lowKey  = (ascending ? getValue(value1) : getValue(value2));
                            KEY_TYPE highKey = (ascending ? getValue(value2) : getValue(value1));
                            if (lowKey > highKey) {
                                data[startIndex + i] = value2;
                                data[startIndex + ixj] = value1;
                            }
                        }
                    }
                    threadgroup_barrier(mem_flags::mem_device);
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Metal-Native Sort: cooperative bitonic sort
// ---------------------------------------------------------------------------

// Single-threadgroup bitonic sort for up to 4096 elements
kernel void nativeBitonicSort4096(
    device uint* data [[buffer(0)]],
    constant uint& length [[buffer(1)]],
    uint localId [[thread_position_in_threadgroup]]
) {
    threadgroup uint buf[4096];
    for (uint m = 0; m < 8; ++m) {
        uint idx = localId * 8 + m;
        buf[idx] = (idx < length) ? data[idx] : 0xFFFFFFFFu;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (uint k = 2; k <= 4096; k *= 2) {
        for (uint j = k / 2; j > 0; j /= 2) {
            threadgroup_barrier(mem_flags::mem_threadgroup);
            for (uint m = 0; m < 4; ++m) {
                uint p = localId * 4 + m;
                uint i = ((p / j) * (2 * j)) + (p % j);
                uint ixj = i + j;
                bool ascending = ((i & k) == 0);
#ifdef MUTATION_NATIVE_SORT
                ascending = !ascending;
#endif
                uint v1 = buf[i];
                uint v2 = buf[ixj];
                if (ascending ? (v1 > v2) : (v1 < v2)) {
                    buf[i] = v2;
                    buf[ixj] = v1;
                }
            }
        }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (uint m = 0; m < 8; ++m) {
        uint idx = localId * 8 + m;
        if (idx < length) {
            data[idx] = buf[idx];
        }
    }
}

// Hierarchical bitonic sort for arrays larger than 4096:
// Phase 1: tile sort of 4096-element chunks
kernel void nativeBitonicLocal4096(
    device uint* data [[buffer(0)]],
    constant uint& totalElements [[buffer(1)]],
    uint localId [[thread_position_in_threadgroup]],
    uint groupId [[threadgroup_position_in_grid]]
) {
    threadgroup uint buf[4096];
    uint base = groupId * 4096;

    for (uint m = 0; m < 8; ++m) {
        uint idx = localId * 8 + m;
        buf[idx] = data[base + idx];
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (uint k = 2; k <= 4096; k *= 2) {
        for (uint j = k / 2; j > 0; j /= 2) {
            threadgroup_barrier(mem_flags::mem_threadgroup);
            for (uint m = 0; m < 4; ++m) {
                uint p = localId * 4 + m;
                uint i = ((p / j) * (2 * j)) + (p % j);
                uint ixj = i + j;
                bool ascending = true;
                if (k < 4096) {
                    ascending = ((i & k) == 0);
                } else {
                    ascending = ((groupId & 1) == 0);
                }
#ifdef MUTATION_NATIVE_SORT
                ascending = !ascending;
#endif
                uint v1 = buf[i];
                uint v2 = buf[ixj];
                if (ascending ? (v1 > v2) : (v1 < v2)) {
                    buf[i] = v2;
                    buf[ixj] = v1;
                }
            }
        }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (uint m = 0; m < 8; ++m) {
        uint idx = localId * 8 + m;
        data[base + idx] = buf[idx];
    }
}

// Phase 2: global bitonic compare-and-swap pass
kernel void nativeBitonicGlobalPass(
    device uint* data [[buffer(0)]],
    constant uint& k [[buffer(1)]],
    constant uint& j [[buffer(2)]],
    uint id [[thread_position_in_grid]]
) {
    uint p = id;
    uint i = ((p / j) * (2 * j)) + (p % j);
    uint ixj = i + j;
    bool ascending = ((i & k) == 0);
#ifdef MUTATION_NATIVE_SORT
    ascending = !ascending;
#endif
    uint v1 = data[i];
    uint v2 = data[ixj];
    if (ascending ? (v1 > v2) : (v1 < v2)) {
        data[i] = v2;
        data[ixj] = v1;
    }
}

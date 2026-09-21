#define NS_PRIVATE_IMPLEMENTATION
#define MTL_PRIVATE_IMPLEMENTATION
#include <Foundation/Foundation.hpp>
#include <Metal/Metal.hpp>

#include <iostream>
#include <vector>

int main() {
    NS::AutoreleasePool* pool = NS::AutoreleasePool::alloc()->init();

    MTL::Device* device = MTL::CreateSystemDefaultDevice();
    if (!device) {
        std::cerr << "Failed to find default Metal device." << std::endl;
        pool->release();
        return 1;
    }

    std::cout << "Using device: " << device->name()->utf8String() << std::endl;

    const char* kernelSource = R"(
        #include <metal_stdlib>
        using namespace metal;

        kernel void square_array(
            device const float* in  [[buffer(0)]],
            device float*       out [[buffer(1)]],
            uint id [[thread_position_in_grid]])
        {
            out[id] = in[id] * in[id];
        }
    )";

    NS::Error* error = nullptr;
    NS::String* sourceStr = NS::String::string(kernelSource, NS::UTF8StringEncoding);
    MTL::CompileOptions* compileOptions = MTL::CompileOptions::alloc()->init();
    MTL::Library* library = device->newLibrary(sourceStr, compileOptions, &error);
    compileOptions->release();

    if (!library) {
        std::cerr << "Failed to compile MSL source: " 
                  << (error ? error->localizedDescription()->utf8String() : "unknown error") 
                  << std::endl;
        device->release();
        pool->release();
        return 1;
    }

    NS::String* funcName = NS::String::string("square_array", NS::UTF8StringEncoding);
    MTL::Function* function = library->newFunction(funcName);
    library->release();

    if (!function) {
        std::cerr << "Failed to find function square_array." << std::endl;
        device->release();
        pool->release();
        return 1;
    }

    MTL::ComputePipelineState* pipelineState = device->newComputePipelineState(function, &error);
    function->release();

    if (!pipelineState) {
        std::cerr << "Failed to create compute pipeline state: "
                  << (error ? error->localizedDescription()->utf8String() : "unknown error")
                  << std::endl;
        device->release();
        pool->release();
        return 1;
    }

    MTL::CommandQueue* queue = device->newCommandQueue();

    const size_t elementCount = 1024;
    const size_t bufferSize = elementCount * sizeof(float);

    MTL::Buffer* inBuffer = device->newBuffer(bufferSize, MTL::ResourceStorageModeShared);
    MTL::Buffer* outBuffer = device->newBuffer(bufferSize, MTL::ResourceStorageModeShared);

    float* inPtr = static_cast<float*>(inBuffer->contents());
    for (size_t i = 0; i < elementCount; ++i) {
        inPtr[i] = static_cast<float>(i);
    }

    MTL::CommandBuffer* cmdBuffer = queue->commandBuffer();
    MTL::ComputeCommandEncoder* encoder = cmdBuffer->computeCommandEncoder();

    encoder->setComputePipelineState(pipelineState);
    encoder->setBuffer(inBuffer, 0, 0);
    encoder->setBuffer(outBuffer, 0, 1);

    MTL::Size gridSize = MTL::Size(elementCount, 1, 1);
    NS::UInteger threadgroupWidth = pipelineState->maxTotalThreadsPerThreadgroup();
    if (threadgroupWidth > elementCount) {
        threadgroupWidth = elementCount;
    }
    MTL::Size threadgroupSize = MTL::Size(threadgroupWidth, 1, 1);

    encoder->dispatchThreads(gridSize, threadgroupSize);
    encoder->endEncoding();

    cmdBuffer->commit();
    cmdBuffer->waitUntilCompleted();

    float* outPtr = static_cast<float*>(outBuffer->contents());
    bool correct = true;
    for (size_t i = 0; i < elementCount; ++i) {
        float expected = static_cast<float>(i * i);
        if (outPtr[i] != expected) {
            std::cerr << "Mismatch at " << i << ": got " << outPtr[i] << ", expected " << expected << std::endl;
            correct = false;
            break;
        }
    }

    if (correct) {
        std::cout << "Compute verification passed: " << elementCount << " elements processed correctly." << std::endl;
    }

    inBuffer->release();
    outBuffer->release();
    pipelineState->release();
    queue->release();
    device->release();

    pool->release();
    return correct ? 0 : 1;
}

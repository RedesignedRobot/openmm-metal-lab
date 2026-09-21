# Metal 4 API and compute command architecture

This reference compares Apple's Metal 4 command model introduced in macOS 26 and updated in macOS 27 with the classic Metal command model. It analyzes the architectural trade-offs for molecular dynamics workloads running 50 to 200 compute kernels per simulation step at thousands of steps per second on Apple silicon.

Primary sources:
- Apple Metal framework headers in macOS 27 SDK: `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/Metal.framework/Headers/`
- Apple Metal Feature Set Tables (dated May 21, 2026). URL: https://developer.apple.com/metal/Metal-Feature-Set-Tables.pdf
- WWDC 2025: "Discover Metal 4" (Session 10123), "Explore Metal 4 games"
- WWDC 2026: "Find and fix performance issues in your Metal games", "Optimize custom machine learning operations with Metal tensors"

## Comparison of command models

### The classic command model
In the classic Metal model (`MTLCommandBuffer`, `MTLComputeCommandEncoder`):
1. Command buffer creation is coupled directly to the command queue via `[MTLCommandQueue commandBuffer]` (`MTLCommandQueue.h`, line 84). Each command buffer is single-use and cannot be recorded in parallel across multiple CPU threads without child buffers (`MTLParallelRenderCommandEncoder` exists for graphics, but compute has no parallel compute encoder).
2. Command buffer memory is managed implicitly by the driver. Every step requires allocating a new command buffer object and underlying command storage.
3. Argument binding uses individual encoder calls (`[encoder setBuffer:offset:atIndex:]`, `[encoder setTexture:atIndex:]`). A kernel with 15 buffer arguments incurs 15 Objective-C message dispatches per kernel launch (`MTLComputeCommandEncoder.h`, line 125).
4. Compute and memory operations require separate encoders. Copying, filling, or synchronizing buffers requires ending the `MTLComputeCommandEncoder`, creating an `MTLBlitCommandEncoder`, encoding blits, ending the blit encoder, and opening a new compute encoder.
5. Resource residency and tracking are handled by driver heuristics or manual `[encoder useResource:usage:]` calls across all bound resources.

### The Metal 4 command model
Metal 4 introduces a reworked execution and allocation model (`MTL4` prefix, available since macOS 26.0; `MTL4CommandBuffer.h`, line 45):
1. `MTL4CommandAllocator`: Manages backing memory for command encoding explicitly (`MTL4CommandAllocator.h`, line 28). The application preallocates allocators and resets them via `-[MTL4CommandAllocator reset]` once the GPU finishes execution (line 50). This reuses backing heaps and eliminates per-step allocation overhead.
2. Decoupled command buffers: `MTL4CommandBuffer` instances are created independently of queues (`MTL4CommandBuffer.h`, line 45). An application starts recording by calling `-[MTL4CommandBuffer beginCommandBufferWithAllocator:]` (line 71) and finishes with `-[MTL4CommandBuffer endCommandBuffer]` (line 103). Multiple threads can encode separate command buffers concurrently using separate allocators.
3. Unified compute and blit encoder: `MTL4ComputeCommandEncoder` consolidates compute dispatches, memory copies, texture copies, buffer clears, and acceleration structure builds into a single encoder (`MTL4ComputeCommandEncoder.h`, lines 27-29). Transitioning from a kernel dispatch to a buffer clear requires zero encoder state transitions.
4. Argument tables (`MTL4ArgumentTable`): Replaces repetitive `setBuffer` calls (`MTL4ArgumentTable.h`, line 58). Resources are bound into an argument table using GPU virtual addresses (`setAddress:atIndex:`) or resource IDs (`setResource:atBufferIndex:`). The encoder sets the entire table in one call: `-[MTL4ComputeCommandEncoder setArgumentTable:]` (`MTL4ComputeCommandEncoder.h`, line 661). Metal takes a snapshot of the table at each dispatch.
5. Explicit residency sets (`MTLResidencySet`): Bundles allocations and heaps into resident groups (`MTLResidencySet.h`, line 47). Calling `[commandBuffer useResidencySet:]` informs the driver of residency in one call, removing per-resource driver validation.
6. `MTL4Compiler` and `MTL4Archive`: Provides dedicated compiler contexts (`MTL4Compiler.h`, line 45) with priority controls and asynchronous compilation tasks. `MTL4Archive` (`MTL4Archive.h`, line 49) stores compiled GPU binaries for zero-overhead startup loading.
7. Tensors: Native `MTLTensor` representation and hardware-accelerated tensor operations integrated into MSL and Metal 4 runtime (`MTLTensor.h`).

## Workload analysis: 50 to 200 kernels per simulation step

In molecular dynamics simulations, an integration step consists of 50 to 200 small kernel dispatches (bonded forces, nonbonded forces, PME spread, FFT, PME gather, constraints, integration). Simulations execute thousands of steps per second with zero CPU readback between steps.

### Lowest per-dispatch CPU overhead
- In the classic model, calling `setBuffer:offset:atIndex:` 10 to 20 times per dispatch across 100 kernels generates 1,000 to 2,000 Objective-C message dispatches per step.
- In Metal 4, argument tables allow writing buffer GPU addresses (`MTLGPUAddress`) into preallocated tables. When kernel arguments remain unchanged between steps, the application does not touch the argument table at all.
- Reusing `MTL4CommandAllocator` instances avoids driver heap allocations during the inner simulation loop.
- Therefore, the Metal 4 model provides significantly lower CPU overhead per dispatch than the classic model.

### Batching dispatches into command buffers
Apple's official guidance across WWDC 2025 and WWDC 2026 emphasizes encoding as many dispatches as possible into a single command buffer:
- Submitting a command buffer incurs kernel-space submission and driver scheduling overhead. Submitting 100 separate command buffers per step destroys performance.
- An entire MD simulation step (all 50 to 200 dispatches) should be encoded into a single `MTL4CommandBuffer` (or single classic `MTLCommandBuffer`).
- For simulations running without CPU intervention for several steps, multiple complete MD steps can be encoded into a single command buffer before submission via `commit`.

### Concurrent versus serial dispatch
In classic compute encoding:
- `MTLDispatchTypeSerial` (default): The GPU executes compute dispatches strictly sequentially in the order encoded. No barriers are required between dependent kernels.
- `MTLDispatchTypeConcurrent`: Created via `-[MTLCommandBuffer computeCommandEncoderWithDispatchType:MTLDispatchTypeConcurrent]` (`MTLCommandBuffer.h`, line 215). Dispatches overlap across GPU compute cores. When kernel B depends on outputs from kernel A, the application must insert explicit memory barriers via `-[MTLComputeCommandEncoder memoryBarrierWithScope:]` (`MTLComputeCommandEncoder.h`, line 281).
In Metal 4:
- Intra-encoder barriers provide fine-grained control: `-[MTL4CommandEncoder barrierAfterEncoderStages:beforeEncoderStages:visibilityOptions:]` (`MTL4CommandEncoder.h`, line 113). Passing `MTLStageDispatch` for both before and after stages synchronizes consecutive dispatches within the same compute encoder.

### Hazard tracking modes
Resource hazard tracking mode (`MTLHazardTrackingMode`, `MTLResource.h`, line 42):
- `MTLHazardTrackingModeTracked` (default for individual buffers): The Metal driver inserts automatic hazard barriers and tracks dependencies between passes. This adds measurable CPU overhead per command.
- `MTLHazardTrackingModeUntracked`: The driver skips dependency tracking entirely. The application assumes full responsibility for inserting fences, events, or barriers.
- For high-frequency MD kernels, setting all simulation buffers to `MTLHazardTrackingModeUntracked` eliminates driver CPU bookkeeping.

### Storage modes on unified memory
Apple silicon features a unified memory architecture (UMA) where CPU cores and GPU cores share the same physical LPDDR DRAM bus:
- `MTLStorageModeShared`: Accessible by both CPU and GPU (`MTLResource.h`, line 56). Coherent across CPU and GPU on Apple silicon without manual cache flushing.
- `MTLStorageModePrivate`: Accessible only by the GPU (`MTLResource.h`, line 62).
Does `MTLStorageModePrivate` pay off for compute buffers on Apple silicon?
- For textures, `Private` enables hardware tile compression (lossless texture compression on all Apple silicon, lossy on Apple8+).
- For linear compute buffers (arrays of coordinates, velocities, forces), both `Shared` and `Private` buffers reside in the exact same physical DRAM. Apple silicon has no dedicated VRAM.
- `Private` buffers prevent CPU access. To upload initial coordinates or read back final states, the application must allocate a shared staging buffer and execute an explicit blit command.
- In benchmarks and Apple documentation, linear buffers show no bandwidth or throughput advantage in `Private` mode over `Shared` mode on Apple silicon.
- For OpenMM compute arrays, `MTLStorageModeShared` with `MTLHazardTrackingModeUntracked` provides direct CPU access for trajectory output and eliminates all staging blits without sacrificing GPU bandwidth.

### Heaps
`MTLHeap` (`MTLHeap.h`, line 54) allocates a single contiguous memory block from which sub-allocations are created (`[heap newBufferWithLength:options:]`):
- Resources allocated from heaps default to `MTLHazardTrackingModeUntracked`.
- Heaps allow fast sub-allocation of scratch buffers (e.g., neighbor-list rebuilding arrays, temporary FFT buffers) without operating system page-table allocation.
- In Metal 4, heaps integrate directly with `MTLResidencySet` (`[residencySet addHeap:heap]`).

### Synchronization primitives

1. Shared events (`MTLSharedEvent`, `MTLEvent.h`, line 79):
   - Monotonically increasing 64-bit integer values.
   - Synchronizes across multiple command queues, across processes, or between the CPU and GPU (`notifyListener:atValue:block:`).
   - Signaled on queue: `-[MTLCommandQueue signalEvent:value:]` or `-[MTL4CommandQueue signalEvent:value:]` (`MTL4CommandQueue.h`, line 266).
   - Waited on queue: `-[MTLCommandQueue waitForEvent:value:]` or `-[MTL4CommandQueue waitForEvent:value:]` (`MTL4CommandQueue.h`, line 274).
2. Fences (`MTLFence`, `MTLFence.h`, line 31):
   - Synchronizes access to resources across separate encoders within the same command buffer or queue.
   - Producer calls `-[encoder updateFence:]`; consumer calls `-[encoder waitForFence:]`.
   - Supported on Apple2 and later (Metal Feature Set Tables, page 3).
3. Barriers in Metal 4 (`MTL4CommandEncoder.h`, lines 70-115):
   - Encoder barriers: `-[MTL4CommandEncoder barrierAfterEncoderStages:beforeEncoderStages:visibilityOptions:]`. Synchronizes commands within the same encoder.
   - Producer queue barriers: `-[MTL4CommandEncoder barrierAfterStages:beforeQueueStages:visibilityOptions:]`. Ensures subsequent encoders in the queue wait for prior work.
   - Consumer queue barriers: `-[MTL4CommandEncoder barrierAfterQueueStages:beforeStages:visibilityOptions:]`. Ensures current encoder waits for prior queue work.
   - Visibility options (`MTL4VisibilityOptions`, lines 19-34): `MTL4VisibilityOptionNone` (execution barrier without cache flush), `MTL4VisibilityOptionDevice` (flushes caches to GPU device memory coherence point), `MTL4VisibilityOptionResourceAlias` (flushes caches for aliased virtual memory).

### Indirect dispatch
Allows kernel launch dimensions to be generated on the GPU rather than specified by the CPU:
- `dispatchThreadgroupsWithIndirectBuffer:threadsPerThreadgroup:` (`MTLComputeCommandEncoder.h`, line 238; `MTL4ComputeCommandEncoder.h`, line 109).
- Buffer contains struct `MTLDispatchThreadgroupsIndirectArguments` (`{ uint32_t threadgroupsPerGrid[3]; }`, 4-byte aligned).
- Supported on Apple3 and later (Metal Feature Set Tables, page 4).
- Indirect Command Buffers (ICB): Pre-recorded compute dispatches stored in an `MTLIndirectCommandBuffer`. The GPU can populate launch grids and pipeline selections into the ICB, then execute them via `executeCommandsInBuffer:withRange:`. Compute ICBs are supported on Apple3 and later (Metal Feature Set Tables, page 4).

## Hardware family and operating system matrix

The following table summarizes requirements for key compute features. Base M2 is Apple8; M3 and M4 are Apple9.

| Feature | Programming Model | Minimum Hardware Family | Apple8 (M2) Support | Apple9 (M3) Support | Header / API Reference |
| :--- | :--- | :--- | :--- | :--- | :--- |
| Metal 4 Core (`MTL4CommandQueue`, `MTL4CommandBuffer`) | Metal 4 | Apple7 (macOS 26+) | Yes | Yes | `MTL4CommandBuffer.h:45` |
| Command Allocators (`MTL4CommandAllocator`) | Metal 4 | Apple7 (macOS 26+) | Yes | Yes | `MTL4CommandAllocator.h:28` |
| Argument Tables (`MTL4ArgumentTable`) | Metal 4 | Apple7 (macOS 26+) | Yes | Yes | `MTL4ArgumentTable.h:58` |
| Unified Compute/Blit Encoder (`MTL4ComputeCommandEncoder`) | Metal 4 | Apple7 (macOS 26+) | Yes | Yes | `MTL4ComputeCommandEncoder.h:31` |
| Command Barriers (`barrierAfterEncoderStages`) | Metal 4 | Apple7 (macOS 26+) | Yes | Yes | `MTL4CommandEncoder.h:113` |
| Dedicated Compilation Contexts (`MTL4Compiler`) | Metal 4 | Apple7 (macOS 26+) | Yes | Yes | `MTL4Compiler.h:45` |
| Residency Sets (`MTLResidencySet`) | Metal 3 & 4 | Apple6 (macOS 15+) | Yes | Yes | `MTLResidencySet.h:47` |
| Argument Buffers Tier 2 | Metal 3 & 4 | Apple6 (macOS 11+) | Yes | Yes | Feature Tables, p. 4 |
| Floating-Point Atomics | Metal 3 & 4 | Apple7 (macOS 13+) | Yes | Yes | Feature Tables, p. 5 |
| Full 64-bit Atomics (add, sub, cas) | Metal 3 & 4 | Apple9 (macOS 14+) | No (min/max only) | Yes | Feature Tables, p. 5, note 7 |
| 64-bit Atomic Min/Max on `ulong` | Metal 3 & 4 | Apple8 (macOS 13+) | Yes | Yes | Feature Tables, p. 5, note 7 |
| SIMD Permute (`simd_shuffle`, `simd_ballot`) | Metal 3 & 4 | Apple6 (macOS 11+) | Yes | Yes | Feature Tables, p. 4 |
| SIMD Reduction (`simd_sum`, `simd_min`) | Metal 3 & 4 | Apple7 (macOS 11+) | Yes | Yes | Feature Tables, p. 4 |
| SIMD Shift and Fill | Metal 3 & 4 | Apple8 (macOS 13+) | Yes | Yes | Feature Tables, p. 4 |
| Indirect Compute Dispatch | Metal 3 & 4 | Apple3 (macOS 10.14+) | Yes | Yes | Feature Tables, p. 4 |
| Resource Heaps (`MTLHeap`) | Metal 3 & 4 | Apple2 (macOS 10.13+) | Yes | Yes | Feature Tables, p. 4 |

## Consequences for an OpenMM Metal platform

1. For base M2 (Apple8) and later, the native platform should target the Metal 4 command model. The combination of `MTL4CommandAllocator`, `MTL4CommandBuffer`, and `MTL4ArgumentTable` eliminates the CPU dispatch overhead that typically limits small-kernel performance in OpenMM.
2. The platform should encode each complete simulation step (all 50 to 200 kernel dispatches) into a single `MTL4CommandBuffer`. Submitting one command buffer per step keeps GPU queues full without overwhelming the driver with submissions.
3. The unified `MTL4ComputeCommandEncoder` eliminates the need to break encoders when clearing force arrays or copying coordinate buffers. A single encoder can interleave kernel dispatches with buffer copy or fill operations.
4. All simulation buffers should use `MTLStorageModeShared` with `MTLHazardTrackingModeUntracked`. On Apple silicon, private buffers provide no bandwidth benefit for linear arrays and force unnecessary staging copies. Untracked mode removes driver tracking overhead; the platform orders dependent kernels using intra-encoder barriers (`barrierAfterEncoderStages:beforeEncoderStages:visibilityOptions:`).
5. All long-lived simulation buffers should be grouped into an `MTLResidencySet` committed at context creation time. This guarantees residency across all simulation steps with zero per-dispatch validation overhead.
6. For dynamic workflows such as nonbonded pair list generation (where the number of interacting atom blocks varies per step), indirect dispatch via `dispatchThreadgroupsWithIndirectBuffer` allows the block-counting kernel to write launch parameters directly to memory, removing CPU-GPU synchronization.

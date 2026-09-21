# MLX Metal backend implementation

This document records the architectural design of Apple's MLX Metal backend (`mlx/backend/metal/` at commit `59d600b5e64c238427d0f8d897ab7c682ef4d3d2`), with comparative analysis against the ggml Metal backend in `llama.cpp` (`ggml/src/ggml-metal/` at commit `6f41ac59e0a49a00483a316a22ada6b04edd2950`).

## Use of metal-cpp

MLX interacts with Metal exclusively through `metal-cpp`, Apple's header-only C++ wrapper around the Objective-C Metal runtime.

### Private implementation instantiation
`metal-cpp` requires macro definitions to instantiate implementation code in exactly one compilation unit. MLX places these macros at the top of `mlx/backend/metal/device.cpp` (lines 8-10):
```cpp
#define NS_PRIVATE_IMPLEMENTATION
#define CA_PRIVATE_IMPLEMENTATION
#define MTL_PRIVATE_IMPLEMENTATION
```
No other translation unit defines these macros.

### Object ownership and pointer wrapping
MLX manages object lifecycles using three smart pointer wrappers provided by `metal-cpp`:
- `NS::SharedPtr<T>`: Reference-counted container that increments and decrements retain counts.
- `NS::TransferPtr(raw_ptr)`: Adopts a newly created object that already has a retain count of 1. MLX uses this for `newCommandQueue()`, `newLibrary()`, `newComputePipelineState()`, and `newFence()` (`mlx/backend/metal/device.cpp`, lines 315, 668, 744, 581).
- `NS::RetainPtr(raw_ptr)`: Increments the retain count upon taking ownership. MLX uses this for `commandBufferWithUnretainedReferences()` and for storing existing device references (`mlx/backend/metal/device.cpp`, lines 323, 579).

### Autorelease pools
`metal-cpp` calls underlying Objective-C APIs that register temporary allocations into thread-local autorelease pools. To prevent unbounded memory growth, MLX defines:
```cpp
NS::SharedPtr<NS::AutoreleasePool> new_scoped_memory_pool() {
  return NS::TransferPtr(NS::AutoreleasePool::alloc()->init());
}
```
MLX invokes `auto pool = new_scoped_memory_pool();` at the start of device initialization (`device.cpp`, line 83), queue creation (`device.cpp`, line 314), synchronisation (`device.cpp`, line 565), kernel compilation (`device.cpp`, line 654), and pipeline creation (`device.cpp`, line 775).

### Device setup and intentional leak
Device discovery in `mlx/backend/metal/device.cpp` (lines 82-102) handles virtualised and headless environments. It first queries `MTL::CopyAllDevices()`. If the returned array is empty, it falls back to `MTL::CreateSystemDefaultDevice()`.

The singleton device instance is allocated on the heap and intentionally leaked (`device.cpp`, lines 910-916):
```cpp
Device& device(mlx::core::Device) {
  static Device* metal_device = new Device;
  return *metal_device;
}
```
The comment in `device.cpp` explains the mechanism: this prevents crashes during application exit when active worker threads or asynchronous callbacks attempt to access Metal objects during or after static destruction.

## Command buffer policy and CPU stall avoidance

### Unretained references
Command buffers are created using `queue_->commandBufferWithUnretainedReferences()` (`mlx/backend/metal/device.cpp`, line 323). This skips Apple's automatic tracking and retaining of every buffer bound in the encoder, reducing CPU overhead during kernel encoding. The caller guarantees that bound buffers stay alive during command buffer execution.

### Batching thresholds and commit triggers
MLX does not commit a command buffer after each kernel dispatch. Instead, it accumulates dispatches in a single compute command encoder and command buffer until one of two thresholds is exceeded (`mlx/backend/metal/device.cpp`, lines 511-514):
```cpp
bool CommandEncoder::needs_commit() const {
  auto [max_ops, max_mb] = device_.get_max_ops_mb_per_buffer();
  return (buffer_ops_ > max_ops) || ((buffer_sizes_ >> 20) > max_mb);
}
```
The default limits depend on GPU core architecture (`device.cpp`, lines 604-624):
- Phone ('p'): 20 operations or 40 MB.
- Base and Pro ('g'): 40 operations or 40 MB.
- Max and Ultra ('s', 'd'): 50 operations or 50 MB.

These defaults can be overridden with environment variables:
- `MLX_MAX_OPS_PER_BUFFER`: Maximum dispatches encoded before a commit (`mlx/utils.h`, lines 193-197).
- `MLX_MAX_MB_PER_BUFFER`: Maximum referenced memory in megabytes before a commit (`mlx/utils.h`, lines 199-203).

### Concurrent encoding and hazard tracking
MLX creates encoders with concurrent dispatch:
```cpp
encoder_ = NS::RetainPtr(buffer_->computeCommandEncoder(MTL::DispatchTypeConcurrent));
```
Because driver hazard tracking is disabled (`MTL::ResourceHazardTrackingModeUntracked`), MLX tracks data hazards explicitly in software (`mlx/backend/metal/device.cpp`, lines 345-406):
1. For inputs, it checks if the buffer pointer exists in `prev_outputs_`. If so, `needs_barrier_` is set to true.
2. For outputs, it checks if the buffer pointer exists in `prev_inputs_`. If so, `needs_barrier_` is set to true.
3. Before issuing `dispatch_threads` or `dispatch_threadgroups`, `maybeInsertBarrier()` is called.
4. If `needs_barrier_` is true, it issues `get_command_encoder()->memoryBarrier(MTL::BarrierScopeBuffers)`.
5. It swaps `prev_inputs_`/`next_inputs_` and `prev_outputs_`/`next_outputs_` without reallocating hash set buckets.

Across distinct command encoders within the same command buffer, MLX coordinates hazards using `MTL::Fence` objects (`device.cpp`, lines 428-485). Each encoder signals its own fence on completion. Successive encoders that read those outputs issue `encoder_->waitForFence(fence)`.

### CPU stall avoidance
To prevent the host CPU from blocking on GPU execution:
- Dispatch and commit calls are asynchronous.
- Error checking is deferred: `buffer_->addCompletedHandler` inspects `cbuf->status()` asynchronously (`device.cpp`, lines 520-557). If an error occurs, the completion handler stores the error in `error_` and marks dependent events.
- Host threads block only when client code explicitly requests evaluation or data readback via `synchronize()` (`device.cpp`, lines 564-574).

## Kernel compilation strategy

MLX uses a hybrid compilation strategy: prebuilt binary metallibs for fixed routines and runtime just-in-time (JIT) compilation for templated operations and graph fusion.

### Prebuilt metallib
When `MLX_METAL_JIT` is disabled or for fixed kernels, MLX loads precompiled libraries via `load_colocated_library` (`mlx/backend/metal/device.cpp`, lines 149-159). It searches for `mlx.metallib` or `Resources/mlx.metallib` relative to the binary path, then checks SwiftPM bundle paths, and finally uses the `METAL_PATH` CMake preprocessor definition (`device.cpp`, lines 195-249).

### Runtime JIT compilation
When runtime JIT is active, kernels are compiled from generated source strings:
```cpp
auto mtl_lib = NS::TransferPtr(device_->newLibrary(ns_code, options, &error));
```
In `mlx/backend/metal/CMakeLists.txt` (lines 1-22), `make_jit_source` converts Metal header files into C++ functions returning string literals (such as `metal::unary()`, `metal::reduce()`, `metal::scatter()`).

In `mlx/backend/metal/jit_kernels.cpp` (lines 48-150), MLX concatenates these source strings with specialized type definitions generated via `get_template_definition`:
```cpp
concatenate(kernel_source, metal::unary_ops(), metal::unary());
kernel_source += get_template_definition("v_" + lib_name, "unary_v", in_t, out_t, op, 1);
```

### Pipeline state cache
Compiled pipelines are cached in two levels within `mlx/backend/metal/device.h` (lines 237-244):
1. `library_map_`: Maps kernel string identifiers to `MTL::Library*`, protected by `library_mtx_` (shared mutex).
2. `library_kernels_`: Maps specialized function names to `MTL::ComputePipelineState*`, protected by `kernel_mtx_` (shared mutex).
Lookups acquire a shared lock for read access. Only cache misses acquire an exclusive lock to compile and insert the pipeline (`device.cpp`, lines 880-895).

### Function constants
For kernels with compile-time configuration flags, MLX configures specialization using `MTL::FunctionConstantValues` (`device.cpp`, lines 704-717). It sets constants by index, builds a `MTL::FunctionDescriptor`, and compiles the specialized function using `mtl_lib->newFunction(desc, &error)`.

### Dynamic kernel fusion
In `mlx/backend/metal/compiled.cpp` (lines 16-150), MLX generates MSL source text on the fly from an expression graph. It traverses the computational tape, writes function signatures with `[[host_name("...")]]`, assigns consecutive `[[buffer(i)]]` indices, emits index decoding logic (`elem_to_loc`), and inlines arithmetic operations into loop bodies.

## Reductions, scans, scatter, and sort

### Reductions
Reduction kernels are implemented in `mlx/backend/metal/kernels/reduce.metal` and `mlx/backend/metal/kernels/reduction/`.

The SIMD reduction uses a two-tier design (`mlx/backend/metal/kernels/reduction/ops.h`, lines 8-20):
1. For data types under 8 bytes (such as float, half, int32), MLX uses Metal builtins: `simd_sum`, `simd_min`, `simd_max`, and `simd_all`.
2. For 8-byte types (such as int64, uint64, complex64), Metal provides no builtin reductions. MLX implements a binary reduction loop using `simd_shuffle_down`:
```cpp
for (short i = simd_size / 2; i > 0; i /= 2) {
  val = operator()(val, simd_shuffle_down(val, i));
}
```

In `all_reduce` (`mlx/backend/metal/kernels/reduction/reduce_all.h`, lines 21-65):
- Threads accumulate multiple values (`N_READS = 4`).
- Each thread performs an in-thread reduction.
- Each SIMD group reduces across its 32 lanes using `op.simd_reduce(total)`.
- Lane 0 writes its SIMD-group result into threadgroup memory: `threadgroup U shared_vals[simd_size];` (line 21).
- After `threadgroup_barrier(mem_flags::mem_threadgroup)`, the first SIMD group loads the partial results from `shared_vals` and executes a final `op.simd_reduce(total)`.
Because threadgroups contain at most 1024 threads (32 SIMD groups), exactly 32 values exist in `shared_vals`. One SIMD group reduces all partial sums in a single step without tree recursion.

For large arrays (> 64 MB), `mlx/backend/metal/reduce.cpp` (lines 361-408) executes in two passes:
- Pass 1 launches multiple threadgroups producing an intermediate array.
- Pass 2 launches a single threadgroup reducing the intermediate array.

### Scans
Scan kernels are implemented in `mlx/backend/metal/kernels/scan.metal` and `mlx/backend/metal/kernels/scan.h`.

SIMD-group prefix scans use builtins for types under 8 bytes:
- `simd_prefix_inclusive_sum(x)`
- `simd_prefix_exclusive_sum(x)`
- `simd_prefix_inclusive_product(x)`
- `simd_prefix_exclusive_product(x)`

For 8-byte types or custom operators (`CumMax`, `CumMin`), MLX synthesizes prefix scans using `simd_shuffle_and_fill_up` (`mlx/backend/metal/kernels/scan.h`, lines 13-19):
```cpp
for (int i = 1; i <= 16; i *= 2) {
  val = operator()(val, simd_shuffle_and_fill_up(val, init, i));
}
```

Across SIMD groups in a threadgroup (`scan.h`, lines 278-295):
- Threadgroup memory stores SIMD group totals: `threadgroup U simdgroup_sums[32];`.
- Each SIMD group calculates its sum and writes to `simdgroup_sums[simd_group_id]`.
- A threadgroup barrier synchronizes writes.
- The first SIMD group scans `simdgroup_sums`.
- A second barrier synchronizes reads.
- Each thread adds its SIMD group's base offset to its local scanned values.

### Scatter
Scatter operations are implemented in `mlx/backend/metal/indexing.cpp` and `mlx/backend/metal/kernels/indexing/scatter.h`.
- Updates write through `device mlx_atomic<T>* out` (`scatter.h`, line 17).
- Each thread evaluates index positions using `elem_to_loc` and invokes `op.atomic_update(out, updates[upd_idx], out_idx)` (`scatter.h`, line 57).
- In `mlx/backend/metal/kernels/atomic.h` (lines 90-112), floating-point atomic operations use `atomic_compare_exchange_weak_explicit`.
- Critical bug workaround in `atomic.h` (lines 98-110): Under fast-math (`no-nans-fp-math`), `atomic_compare_exchange_weak_explicit<float>` lowers to `fcmp fast ueq`. If memory contains NaN, the equality test evaluates to false even when bits match, causing an infinite CAS loop. MLX explicitly checks `if (isnan(expected)) break;` to prevent GPU hangs.

### Sort
Sorting is implemented in `mlx/backend/metal/sort.cpp` and `mlx/backend/metal/kernels/sort.h`.
- MLX uses a block merge sort ported from NVIDIA's CUB library (`sort.h`, line 8).
- For single-block sort, threadgroup size matches block dimension `bn` (32 to 512 threads).
- Phase 1 executes an odd-even sort in thread-private registers (`ThreadSort`, `sort.h`, lines 60-84).
- Phase 2 merges sorted sequences hierarchically using threadgroup shared memory and `threadgroup_barrier`.
- For multi-block sort, MLX partitions inputs into tiles and runs multiple merge passes.

### Threadgroup sizing rules
In `mlx/backend/common/utils.cpp` (lines 118-147), `get_block_dims_common` determines threadgroup dimensions:
- It iteratively increases power-of-two factors across dims 0, 1, and 2 until their product reaches 1024 (`sum == 10`) or fits problem dimensions.
- Reductions and scans snap threadgroup sizes to multiples of 32 (`((size + 31) / 32) * 32`) to ensure full SIMD group occupancy.

## Buffer allocator

The allocator lives in `mlx/backend/metal/allocator.h` and `allocator.cpp`.

### Heaps
To eliminate driver allocation latency for small temporary buffers, MLX creates a 1 MB sub-allocated heap during initialization (`allocator.cpp`, lines 71-77):
```cpp
heap_desc->setSize(1 << 20); // 1 MB heap
heap_ = NS::TransferPtr(device_->newHeap(heap_desc));
```
Allocations smaller than 256 bytes (`small_size_ = 256`) are placed on this heap (`allocator.cpp`, line 149).

### Storage modes and hazard tracking
All buffers and heaps use explicit storage and hazard flags (`allocator.cpp`, lines 15-16):
```cpp
constexpr size_t resource_options =
    MTL::ResourceStorageModeShared | MTL::ResourceHazardTrackingModeUntracked;
```
- `ResourceStorageModeShared`: Places allocations in Apple Silicon unified memory, accessible by both CPU and GPU without copies.
- `ResourceHazardTrackingModeUntracked`: Disables Metal's internal automatic barrier insertion, leaving dependency management to MLX's software tracking.

### Buffer cache
The allocator wraps allocations in `BufferCache<MTL::Buffer>` (`allocator.cpp`, lines 48-57).
- Allocations are rounded up to multiples of system page size (`vm_page_size = 16384` bytes on Apple Silicon).
- Freed buffers are returned to the free list cache rather than being deallocated to the OS (`allocator.cpp`, lines 183-201).
- Memory limits are derived from system parameters (`allocator.cpp`, lines 58-65):
  * `block_limit_`: `std::min(1.5 * max_rec_size, 0.95 * memsize)`.
  * `gc_limit_`: `std::min(0.95 * max_rec_size, block_limit_)`.
- When allocations exceed `gc_limit_`, the allocator evicts cached buffers to satisfy memory pressure.

### Residency sets
MLX manages GPU page residency via `MTL::ResidencySet` (`mlx/backend/metal/resident.h` and `resident.cpp`).
- Keeps allocations pinned in GPU memory up to the wired limit set by `set_wired_limit()` (defaults to 0).
- Allocations are distributed across multiple size-capped residency sets instead of one giant set. If a set loses residency under memory pressure, only its allocations need repinning.
- Capped by `MLX_RESIDENCY_SET_MAX_PCT` (`utils.h`, lines 209-212, default 5% of `recommendedMaxWorkingSetSize`).
- Maximum number of residency sets per queue is capped at 32 (`kMaxSets = 32`, `resident.h`, line 80) in accordance with the Metal Feature Set Tables.
- Unattached sets are attached to the command queue at commit time (`device.cpp`, line 519).

## Hardware generations and OS version branching

MLX inspects GPU hardware and OS capabilities at runtime.

### Architecture parsing
In `mlx/backend/metal/device.cpp` (lines 589-624), MLX reads `device_->architecture()->name()`.
- It parses generation tens and ones digits (e.g. Apple7, Apple8, Apple9).
- It checks the trailing character (`arch_.back()`):
  * `'p'`: Phone. Max 20 ops / 40 MB per buffer.
  * `'g'`: Base and Pro. Max 40 ops / 40 MB per buffer.
  * `'s'`: Max. Max 50 ops / 50 MB per buffer.
  * `'d'`: Ultra. Max 50 ops / 50 MB per buffer.
The environment variable `MLX_METAL_GPU_ARCH` can force an architecture string (`device.cpp`, line 589).

### Operating system and Metal language versions
`get_metal_version()` selects the Metal language version based on OS availability macros (`device.cpp`, lines 65-80):
- macOS 27+: Returns language version `(4 << 16) + 1` (Metal 4.1).
- macOS 26+: Returns `MTL::LanguageVersion4_0` (Metal 4.0).
- macOS 15+: Returns `MTL::LanguageVersion3_2`.
- Older: Returns `MTL::LanguageVersion3_1`.

### Neural Accelerator (NAX) on M5 / A18
MLX contains dedicated kernel implementations utilizing the on-chip Neural Accelerator (NAX) for GEMM and attention (`mlx/backend/metal/device.cpp`, lines 947-966):
```cpp
bool is_nax_available() {
  bool can_use_nax = false;
  if (__builtin_available(macOS 26.2, iOS 26.2, tvOS 26.2, visionOS 26.2, *)) {
    can_use_nax = true;
  }
  auto& d = metal::device(mlx::core::Device::gpu);
  auto arch = d.get_architecture().back();
  auto gen = d.get_architecture_gen();
  can_use_nax &= gen >= (arch == 'p' ? 18 : 17);
  return can_use_nax;
}
```
NAX is enabled only on macOS 26.2 or later on GPU generation 17 or higher (or 18 on phone). On older SDKs or OS versions, `MLX_METAL_NO_NAX` is defined at build time (`CMakeLists.txt`, line 113).

## Fast-math settings

### Offline metallib compilation
In `mlx/backend/metal/kernels/CMakeLists.txt` (line 18), MLX explicitly disables fast math for offline kernel compilation:
```cmake
set(METAL_FLAGS
    -x metal
    -Wall
    -Wextra
    -fno-fast-math
    -Wno-c++17-extensions
    -Wno-c++20-extensions
    -Wmetal-addr-spaces)
```

### Runtime compilation options
In `mlx/backend/metal/device.cpp` (lines 37-63), `set_compile_options` handles runtime JIT flags:
- On macOS 15+, it calls `options->setMathMode()` with `MTL::MathModeSafe`, `MTL::MathModeRelaxed`, or `MTL::MathModeFast`.
- On older macOS, it calls `options->setFastMathEnabled()`.
- Default math mode across MLX is `MathMode::Safe` (`mlx/backend/common/metal_kernel.h`, line 14).

### Rationale for disabling fast math
Fast math permits unsafe floating-point transformations:
- In associative floating-point arithmetic, reassociation breaks bitwise determinism and produces energy drift in numerical integration.
- Fast math assumes no NaNs (`no-nans-fp-math`), which converts floating-point equality comparisons with NaN to false, breaking atomic CAS loops (`atomic.h`, line 100).
- Disabling fast math maintains IEEE-754 compliance for critical numerical kernels.

## Comparison with ggml Metal backend

The ggml backend in `llama.cpp` (`ggml/src/ggml-metal/`) implements different architectural choices:

| Area | MLX Metal Backend | ggml Metal Backend | Rationale for ggml choice |
| --- | --- | --- | --- |
| Host language and bindings | C++17 via Apple `metal-cpp` (`device.cpp`, lines 8-16) | Objective-C and C (`.m` files, MRC `[obj release]`, `ggml-metal-device.m`, line 1) | llama.cpp avoids C++17 dependencies; Objective-C provides direct access to Cocoa/Metal APIs without wrapper headers. |
| Command buffer dispatch | Sequential encoding into a single command buffer; commits after 20-50 dispatches (`device.cpp`, line 512) | Parallel encoding across `n_cb` command buffers via GCD `dispatch_apply` (`ggml-metal-context.m`, line 593) | Encoding hundreds of attention layers serially on a single CPU thread bottlenecks LLM execution; ggml parallelizes encoding across CPU cores. |
| Command buffer reference tracking | `commandBufferWithUnretainedReferences` (`device.cpp`, line 323) | `commandBufferWithUnretainedReferences` (`ggml-metal-context.m`, line 555) | Both backends bypass driver reference tracking to minimize CPU overhead. |
| Kernel compilation | Offline `mlx.metallib` with runtime JIT string templating (`jit_kernels.cpp`) | Embedded assembly text chunks (`.section __DATA,__ggml_metallib`) compiled at startup, or `default.metallib` (`CMakeLists.txt`, lines 56-116) | Embedding source text in binary data sections allows a single standalone executable without external `.metallib` files while retaining runtime driver optimization. |
| Memory allocator | Sub-allocated 1 MB heap for < 256 B (`allocator.cpp`, line 74) + page-aligned buffer cache | Direct allocations via `newBufferWithBytesNoCopy` or `device->newBuffer` | ggml manages tensor buffers in large pre-allocated slabs; MLX handles dynamic creation of fine-grained arrays. |
| Residency sets | Sized residency sets (5% cap, max 32 sets) attached per commit (`resident.h`) | Single residency set per context (`GGML_METAL_HAS_RESIDENCY_SETS`, `ggml-metal-device.m`, line 24) | ggml wires all model weights in bulk; MLX dynamically balances residency against memory pressure. |
| Fast math | `-fno-fast-math` and `MathMode::Safe` by default | `-O3` default in release; `-fno-fast-math` in debug only (`CMakeLists.txt`, line 149) | LLM inference tolerates floating-point reassociation and benefits from faster reciprocal and exponential approximations. |
| Hardware specialization | Checks architecture string ('p', 'g', 's', 'd'), supports NAX on M5 | Checks `MTLGPUFamily` features (e.g. `has_bfloat`, `has_tensor`, `MTLGPUFamilyMetal4`) | ggml focuses on feature set flags rather than chip generation numbers. |

## Consequences for an OpenMM Metal platform

1. **Adopt metal-cpp in private compilation units**: OpenMM lead maintainer Peter Eastman rejects Objective-C in the codebase. Packaging `metal-cpp` inside private C++17 files (`.cpp`), while keeping OpenMM's public API at C++11, satisfies this requirement. Exactly one compilation unit must define `MTL_PRIVATE_IMPLEMENTATION`.
2. **Batch kernel dispatches into shared command buffers**: NORPG's current branch creates and commits a new command buffer on every single kernel execution (`platforms/metal/src/MetalKernel.mm`, lines 71-87). This causes severe CPU and firmware latency. OpenMM must maintain an active command buffer across multiple kernels in a simulation step, committing only when synchronisation is required or when operation limits (40-50 dispatches) are reached.
3. **Use unretained references on command buffers**: OpenMM owns its persistent force and state buffers. Constructing command buffers with `commandBufferWithUnretainedReferences()` removes driver retain overhead on every launch.
4. **Disable driver hazard tracking**: Enabling `MTL::ResourceHazardTrackingModeUntracked` eliminates driver-side tracking overhead. OpenMM can manage barriers between compute passes using `memoryBarrier(MTL::BarrierScopeBuffers)` within concurrent encoders.
5. **Enforce IEEE-safe math**: OpenMM must pass `-fno-fast-math` to offline compilers and set `MathMode::Safe` during runtime compilation. Enabling fast math causes energy drift from non-associative additions and triggers infinite loops in floating-point CAS atomics if NaNs occur.
6. **Use SIMD builtins for 32-wide reductions**: Reductions across 32 threads should use `simd_sum`, `simd_min`, and `simd_max` instead of threadgroup memory. Threadgroup memory should only bridge partial sums between different SIMD groups.
7. **Allocate pinned shared memory for transfers**: CPU-GPU copies must use shared memory buffers (`MTL::ResourceStorageModeShared`) to allow zero-copy staging, avoiding synchronous blit operations during time-step integration.

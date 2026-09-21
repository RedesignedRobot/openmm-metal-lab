# Experiment 013 results

This document reports test execution results for the Metal platform in NORPG/openmm branch Objective-C at commit 8f6a7332f4bca326cd43366f2916da396db661ae.

## Test results

OpenMM registered one test for the Metal platform in CTest: `TestMetalComputeContext`.
The test ran on two hardware targets: Apple M3 Ultra and Apple M2.

### Apple M3 Ultra

Hardware specifications: Apple M3 Ultra, 28 CPU cores, 60 GPU cores, 128 GB unified memory.
Operating system: macOS 27.0.
Compiler: AppleClang 21.0.0 (Command Line Tools 27.0.0.0.1788430756).
Test execution log: `/tmp/ctest-m3ultra.log`.

| Test | Status | Seconds | First failure line | Cause |
| --- | --- | --- | --- | --- |
| TestMetalComputeContext | Passed | 0.94 | none | none (passed) |

### Apple M2

Hardware specifications: Apple M2, 8 CPU cores, 10 GPU cores, 8 GB unified memory.
Operating system: macOS 27.0.
Compiler: AppleClang 21.0.0 (Command Line Tools 27.0.0.0.1788430756).
Test execution log: `/tmp/ctest-m2mini.log`.

| Test | Status | Seconds | First failure line | Cause |
| --- | --- | --- | --- | --- |
| TestMetalComputeContext | Passed | 1.31 | none | none (passed) |

## Test coverage and verification scope

The test executable `TestMetalComputeContext` validates the Common compute runtime interfaces implemented in the branch.
The test runs against standalone native Metal Shading Language kernels in `platforms/metal/tests/kernels/runtime.metal`.

The test verified seven functional areas:

- Context parameters: Reports 1 context, single precision mode, no mixed precision, no double precision, and no 64-bit global atomic support.
- Arrays and memory transfers: Validates array initialization, buffer resizing, synchronous host uploads and downloads, subarray transfers, array copying on device, and pinned buffer transfers.
- Kernel execution: Dispatches the `transform` kernel across multiple grid sizes (1, 63, 64, 65, 129, and 8,321 threads) with 64 threads per group, testing the grid-stride execution model. Dispatches the `recordGroupWidth` kernel to verify threadgroup barriers and group sizes.
- Argument binding: Validates kernel argument configuration, primitive scalar arguments, array buffer bindings, argument rebinding after array resizing, and unbound argument detection.
- Buffer clearing: Validates GPU memory zeroing through blit encoders for arbitrary arrays and context-registered autoclear buffers.
- Multi-queue and event synchronization: Creates a secondary command queue, enqueues events on one queue, waits on another queue via `encodeWaitForEvent:value:`, and verifies that asynchronous transfers and compute dependencies preserve memory ordering.
- Error handling: Confirms that unsupported OpenMM simulation calls (`getContextImpl()`, `getIntegrationUtilities()`, `getNonbondedUtilities()`), invalid shader sources, missing kernel names, and cross-context array copies throw `OpenMMException`.

## Architectural observations

Inspection of the branch code reveals several design details that relate to earlier lab findings:

- Runtime compilation: Shaders compile at runtime using `[MTLDevice newLibraryWithSource:options:error:]` in `platforms/metal/src/MetalContext.mm`. No offline Metal compiler binary (`metal`) is required.
- Dispatch latency: In `platforms/metal/src/MetalKernel.mm`, every invocation of `execute` creates a new `MTLCommandBuffer` and immediately commits it. Experiment 008 showed that dispatching one command buffer per kernel adds 15 microseconds on the M3 Ultra and 24 microseconds on the M2, whereas whole-step batching requires 0.11 microseconds.
- Language version floor: The branch sets `options.languageVersion = MTLLanguageVersion3_0`. As established in Experiment 007, program-scope builtins proposed for upstream OpenMM require MSL 3.1, which sets macOS 14 as the platform floor.
- Fast math configuration: The branch sets `options.fastMathEnabled = YES`. Experiment 007 showed that safe math (`mathMode = .safe`) is required to maintain numerical agreement with OpenCL (fast math reduces asin agreement to 43%).
- Command buffer completion: In `platforms/metal/src/MetalQueue.mm`, `MetalQueue::wait` checks `marker.status < MTLCommandBufferStatusCommitted` and raises an `OpenMMException` if the buffer is uncommitted. This prevents the indefinite hang identified in Experiment 008 where waiting on an uncommitted buffer stalls indefinitely.

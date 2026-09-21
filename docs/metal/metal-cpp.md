# metal-cpp for compute engines

This reference describes Apple's `metal-cpp` library, its memory management conventions, SDK coverage, and integration strategies for C++ codebases that do not permit Objective-C.

Primary sources:
- metal-cpp repository cloned into `/Users/mas/code/metal-ref/` (newest tag: `release/metal-cpp_macOS27_iOS27`, commit `27c4382`, matching macOS 27 and iOS 27 SDKs)
- `LICENSE.txt` and `README.md` in `/Users/mas/code/metal-ref/`
- Apple Developer metal-cpp portal: https://developer.apple.com/metal/cpp/
- Verification test located in `docs/metal/examples/metal-cpp-min/`

## Library identity and licensing

`metal-cpp` is a header-only C++ interface generated directly from Apple's Metal, Foundation, QuartzCore, and MetalFX Objective-C headers (`README.md`, lines 1-17). It enables C++ programs to invoke Metal API functions directly without Objective-C or Objective-C++ source files (`.m` or `.mm`).

Key properties:
- License: Apache License, Version 2.0, dated January 2004 (Copyright 2024 Apple Inc., `LICENSE.txt`, lines 1-203). It contains standard commercial-use, modification, and redistribution permissions without restrictive copyleft requirements.
- Header-only architecture: All implementation code resides inside inline C++ templates and header definitions. Calling functions in `metal-cpp` generates inline calls to `objc_msgSend` targeting the system Metal framework (`-framework Metal -framework Foundation`).
- C++ standard requirement: Requires C++17 or later (`README.md`, line 13). The library relies on C++17 `constexpr` constructs inside `NS::Object`.
- Performance overhead: Zero measurable overhead compared to direct Objective-C calls because C++ method calls inline directly to the underlying runtime message dispatch (`README.md`, line 11).

## Build integration and implementation macros

To use `metal-cpp`, add the repository root to the compiler's include path (`-I/path/to/metal-cpp`).

In exactly one translation unit (`.cpp` file) in the binary or library, define the private implementation macros before including the headers (`README.md`, lines 98-107):

```cpp
#define NS_PRIVATE_IMPLEMENTATION
#define MTL_PRIVATE_IMPLEMENTATION
#define CA_PRIVATE_IMPLEMENTATION // If using QuartzCore / CA::MetalLayer
#include <Foundation/Foundation.hpp>
#include <Metal/Metal.hpp>
```

In all other translation units, omit the `*_PRIVATE_IMPLEMENTATION` defines and include `<Foundation/Foundation.hpp>` and `<Metal/Metal.hpp>` normally. Defining the macros in multiple translation units causes duplicate symbol linker errors. Omitting the macros everywhere causes undefined symbol linker errors for class and selector initializers.

## Memory management rules

`metal-cpp` mirrors Cocoa and CoreFoundation reference-counting semantics without automatic reference counting (ARC) (`README.md`, lines 33-91):

### Ownership conventions
1. Methods beginning with `alloc`, `new`, `copy`, `mutableCopy`, or `Create` return objects with a retain count of 1. The caller owns the returned object and must release it when finished.
2. Methods not beginning with those words return autoreleased objects owned by the active autorelease pool. The caller must not call `release()` on them directly unless the caller first calls `retain()`.
3. An object is destroyed immediately when its retain count drops to 0. Calling methods on a deallocated object causes undefined behavior or crashes.
4. Calling methods on `nullptr` is legal and acts as a no-op, matching Objective-C `nil` semantics (`README.md`, line 94).

### Autorelease pools
Autoreleased objects are placed in the nearest enclosing `NS::AutoreleasePool` (`README.md`, lines 46-73):
- Code must establish an autorelease pool using `NS::AutoreleasePool* pool = NS::AutoreleasePool::alloc()->init();`.
- Draining the pool via `pool->release();` deallocates all accumulated autoreleased objects.
- In long-running simulation loops, code should wrap loop iterations or batches in an autorelease pool to prevent memory growth.
- Setting the environment variable `OBJC_DEBUG_MISSING_POOLS=YES` logs warnings if code leaks autoreleased objects on threads without an active pool (`README.md`, line 70).

### Smart pointers
`metal-cpp` provides `NS::SharedPtr<T>` to automate reference counting (`README.md`, lines 74-90):
- `NS::TransferPtr(rawPointer)`: Wraps a newly allocated object (retain count 1) without incrementing the retain count. The `NS::SharedPtr` destructor calls `release()`. This is the standard RAII wrapper for `newBuffer`, `newCommandQueue`, and `newComputePipelineState`.
- `NS::RetainPtr(rawPointer)`: Increments the retain count and wraps the object. Use this to take shared ownership of autoreleased objects or objects passed from external scopes.

## Metal 4 and macOS 27 SDK coverage

The cloned repository at `/Users/mas/code/metal-ref` carries git tag `release/metal-cpp_macOS27_iOS27` (commit `27c4382`). It fully covers the Metal 4 API and the macOS 27 SDK:
- All Metal 4 headers exist under `Metal/`: `MTL4CommandQueue.hpp`, `MTL4CommandBuffer.hpp`, `MTL4ComputeCommandEncoder.hpp`, `MTL4CommandAllocator.hpp`, `MTL4ArgumentTable.hpp`, `MTL4Compiler.hpp`, `MTL4Archive.hpp`, `MTL4Counters.hpp`, `MTLTensor.hpp`.
- All types, methods, enums, and options match macOS 27.0 headers in `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/Metal.framework/Headers/`.

## Stability promises and backward compatibility

Apple maintains `metal-cpp` as an official project on GitHub (`github.com/apple/metal-cpp`). The library provides explicit backward compatibility mechanisms (`README.md`, lines 15-16):
- Method inspection: All `supports...()` member functions on `MTL::Device` check whether the underlying selector exists in the runtime on the host operating system. If run on an older macOS version lacking the selector, the function safely returns `false` instead of aborting.
- String constants: Framework error domain strings are weak-linked. If an error domain constant does not exist in the host runtime, the pointer resolves to `nullptr`.

## Minimal complete verification example

The repository contains a minimal verification program in `docs/metal/examples/metal-cpp-min/`:
- `main.cpp`: Written in standard C++17. Compiles MSL compute kernel source at runtime via `device->newLibrary()`, sets up an input and output buffer, encodes a compute dispatch, commits the command buffer, and verifies results on the CPU.
- `build.sh`: Builds and runs the executable using the Command Line Tools Clang compiler without Xcode:
  ```bash
  xcrun -sdk macosx clang++ -std=c++17 \
      -isysroot $(xcrun --show-sdk-path) \
      -I/Users/mas/code/metal-ref \
      -framework Metal -framework Foundation \
      main.cpp -o min_compute
  ```
- Verification result: The binary compiles cleanly with Apple Clang 21.0.0 and executes successfully on the local Apple silicon GPU (`Using device: Apple M3 Ultra; Compute verification passed: 1024 elements processed correctly`).

## Confining metal-cpp within an OpenMM codebase

OpenMM's lead maintainer has set two strict architectural constraints:
1. No Objective-C or Objective-C++ in the codebase (no `.m` or `.mm` files).
2. OpenMM's core and common platform code targets C++11.

`metal-cpp` fulfills constraint 1 completely: it is 100% standard C++ and requires zero Objective-C files.
However, `metal-cpp` requires C++17 (`constexpr` inside `NS::Object`). If included in OpenMM's public or common headers, it would force the entire OpenMM library and downstream client code to compile as C++17.

### Recommended isolation architecture: PIMPL pattern
To confine `metal-cpp` to private implementation files:
1. Public and internal OpenMM headers (`MetalPlatform.h`, `MetalContext.h`, `MetalArray.h`) remain pure C++11. They must never include `<Metal/Metal.hpp>` or `<Foundation/Foundation.hpp>`.
2. All Metal objects are held through opaque implementation structs or pointers to implementation (PIMPL):
   ```cpp
   // In public/internal header: MetalContext.h (compiled as C++11)
   class MetalContextImpl;
   class MetalContext {
   public:
       MetalContext();
       ~MetalContext();
       void executeKernel(/* parameters */);
   private:
       MetalContextImpl* pimpl;
   };
   ```
3. Only the implementation files in `platforms/metal/src/` (`MetalContext.cpp`, `MetalKernel.cpp`, `MetalArray.cpp`) include `Metal/Metal.hpp`.
4. In CMake, only the `OpenMMMetal` target sets the compiler flag `target_compile_features(OpenMMMetal PRIVATE cxx_std_17)`. The rest of OpenMM builds under `-std=c++11`.
5. Clang uses the standard Itanium C++ ABI across both C++11 and C++17 modes on macOS. Opaque pointers passed across the boundary incur zero ABI divergence or link incompatibility.

## Consequences for an OpenMM Metal platform

1. `metal-cpp` provides the exact vehicle required to build a native Metal platform for OpenMM. It completely eliminates Objective-C syntax from the repository while retaining full native performance.
2. The platform must isolate all `MTL::*` types behind PIMPL classes in `platforms/metal/src/`. This keeps OpenMM's public API C++11 compliant while allowing the Metal backend translation units to compile under C++17.
3. Memory management within the platform should use `NS::TransferPtr` and `NS::SharedPtr` for device, pipeline, and queue wrappers, eliminating manual retain and release leaks.
4. The compute loop must wrap each batch of steps in an `NS::AutoreleasePool` to ensure temporary autoreleased Foundation objects created during dispatch do not leak over long simulation runs.
5. Because `metal-cpp` tag `release/metal-cpp_macOS27_iOS27` includes complete Metal 4 headers, the platform implementation can directly adopt `MTL4CommandQueue`, `MTL4CommandBuffer`, and `MTL4ArgumentTable` without writing hand-crafted Objective-C bindings.

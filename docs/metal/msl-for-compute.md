# MSL for compute

This reference describes the Metal Shading Language (MSL) for compute kernel development on Apple silicon, targeting macOS 27 and Metal 4.1.

Primary sources:
- Metal Shading Language Specification, Version 4.1 (dated June 4, 2026). URL: https://developer.apple.com/metal/Metal-Shading-Language-Specification.pdf
- Metal Feature Set Tables (dated May 21, 2026). URL: https://developer.apple.com/metal/Metal-Feature-Set-Tables.pdf
- Apple Metal framework headers in macOS 27 SDK: `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/Metal.framework/Headers/`
- Apple metal-cpp headers (tag `release/metal-cpp_macOS27_iOS27`): `/Users/mas/code/metal-ref/`

## Kernel argument rules

### Address spaces
MSL isolates memory into disjoint address spaces (MSL Spec 4.1, section 4, pages 118-122). Every pointer or reference parameter in a compute kernel requires an address space attribute:
1. `device`: Read-write buffer memory objects allocated from device memory (section 4.1, page 118). Metal requires that distinct `device` buffer arguments do not alias; memory passed to one argument must not overlap memory passed to another argument of the same kernel invocation (section 5.2, page 134).
2. `constant`: Read-only buffer memory objects allocated from device memory (section 4.2, page 119). Variables declared at program scope must reside in the `constant` address space and require compile-time initialization with core constant expressions. The minimum buffer offset alignment on all Apple silicon families is 4 bytes (Metal Feature Set Tables, page 8).
3. `threadgroup`: Shared memory allocated per threadgroup and shared among its threads (section 4.4, page 120). Data does not persist across separate threadgroup invocations. Compute units allocate threadgroup memory in multiples of 16 bytes. Maximum allocation per threadgroup is 32 KB on Apple4 through Apple10 GPUs (Metal Feature Set Tables, page 7).
4. `thread`: Per-thread private storage (registers and local stack space, section 4.3, page 120). Variables declared inside kernel functions default to the `thread` address space.
5. Other specialized address spaces: `threadgroup_imageblock` (section 4.5, page 121), `ray_data` (section 4.6, page 122), and `object_data` (section 4.7, page 122).

### Buffer attributes and omitting buffer indices
Kernel buffer parameters receive bindings via the `[[buffer(n)]]` attribute (section 5.2.1, pages 134-136):
- If the developer omits `[[buffer(n)]]`, the Metal compiler automatically assigns location indices starting with the first available unused index (section 5.2.1, page 135).
- If some arguments define explicit indices and others omit them, the compiler assigns unindexed arguments the lowest unused indices, skipping indices claimed by explicit bindings or function constants (section 5.2.1, page 135).
- Reusing the same index for multiple buffer arguments causes a compile error unless guarded by mutually exclusive function constants (section 5.2.1, page 136).

### Buffer count limits
The direct buffer argument table accepts at most 31 buffer entries per kernel function (`[[buffer(0)]]` through `[[buffer(30)]]`). This 31-buffer limit applies across every Apple family from Apple2 through Apple10 (Metal Feature Set Tables, page 7, "Maximum number of entries in the buffer argument table, per graphics or kernel function"). The threadgroup memory argument table also permits a maximum of 31 entries (`[[threadgroup(0)]]` through `[[threadgroup(30)]]`).

### Argument buffers and hardware tiers
Argument buffers group buffers, textures, samplers, and inline constants into a single C++ structure passed via a single buffer slot (MSL Spec 4.1, section 2.13, pages 54-57):
- Tier 1 hardware support: Available on Apple2 and later. Allows up to 31 buffers per stage (Apple2-3) or 96 buffers per stage (Apple4-5) (Metal Feature Set Tables, page 8).
- Tier 2 hardware support: Available on Apple6 and later (A13, M1, M2, M3, M4, M5; Metal Feature Set Tables, page 4 and page 8). Tier 2 eliminates the buffer count cap ("No limit" on buffers accessed per stage). Tier 2 allows up to 1,000,000 textures per stage and up to 996 samplers (Apple7-8) or 500,000 samplers (Apple9-10).
- Tier 2 capabilities: Shaders can index arrays of argument buffers directly with pointers (`constant Resources *resArray`). Shaders can store pointers inside structs (`struct Material { device Textures *textures; };`), copy resources between structures at runtime, and write directly into argument buffers from compute kernels (section 2.13.1, pages 56-57).

## Thread and threadgroup identifiers

MSL supplies execution grid coordinates to kernels through built-in parameter attributes (MSL Spec 4.1, section 5.2.3.6, Table 5.8, pages 154-158). Scalar or vector unsigned integer types (`uint`, `uint2`, `uint3`, `ushort`, `ushort2`, `ushort3`) receive these values:
- `[[thread_position_in_grid]]`: Absolute coordinate of the thread within the complete launch grid.
- `[[thread_position_in_threadgroup]]`: Coordinate of the thread within its threadgroup.
- `[[threadgroup_position_in_grid]]`: Coordinate of the threadgroup within the grid.
- `[[threads_per_grid]]`: Total dimensions of the launch grid.
- `[[threads_per_threadgroup]]`: Actual dimensions of the current threadgroup. When grid sizes do not divide evenly into threadgroups, edge threadgroups reflect the truncated size.
- `[[threadgroups_per_grid]]`: Number of threadgroups dispatched in each dimension.
- `[[thread_index_in_threadgroup]]`: Linear 1D index of the thread inside the threadgroup (`ly * Sx + lx`).
- `[[thread_index_in_simdgroup]]`: Lane ID within the SIMD group. Takes values from 0 to `threads_per_simdgroup - 1` (0 to 31 on Apple silicon).
- `[[simdgroup_index_in_threadgroup]]`: Linear index of the SIMD group inside the threadgroup (`0` to `simdgroups_per_threadgroup - 1`).
- `[[simdgroups_per_threadgroup]]`: Total number of SIMD groups in the threadgroup. Computed as `ceil(threads_per_threadgroup / threads_per_simdgroup)`.
- `[[threads_per_simdgroup]]`: Number of threads per SIMD group (constant 32 on Apple silicon). Replaces deprecated `[[thread_execution_width]]`.
- Quad-group attributes: `[[thread_index_in_quadgroup]]` (0 to 3), `[[quadgroup_index_in_threadgroup]]`, `[[quadgroups_per_threadgroup]]`.
- Program-scope built-ins: Starting in Metal 3.1, kernels can declare built-in position variables at global program scope instead of listing them as kernel parameters (section 5.2, pages 133-134).

## SIMD-group and quad-group functions

SIMD-group functions execute across threads in a single 32-thread SIMD group without threadgroup memory and without barrier instructions (MSL Spec 4.1, section 6.10.2, pages 217-226). Supported types `T` include all scalar and vector integer and floating-point types (`char`, `short`, `int`, `half`, `float`), but explicitly exclude `bool`, `bfloat`, `long`, `ulong`, `void`, `size_t`, and `ptrdiff_t` (section 6.10.2, page 218).

### Reduction functions
Broadcasts the reduced scalar or vector result to all active threads in the SIMD group (Table 6.15, pages 221-223):
- `T simd_sum(T data)`: Sum of `data` across all active threads.
- `T simd_product(T data)`: Product of `data` across all active threads.
- `T simd_min(T data)`: Minimum value of `data` across all active threads.
- `T simd_max(T data)`: Maximum value of `data` across all active threads.
- `Ti simd_and(Ti data)`: Bitwise AND across active threads.
- `Ti simd_or(Ti data)`: Bitwise OR across active threads.
- `Ti simd_xor(Ti data)`: Bitwise XOR across active threads.

### Prefix operations
Computes cumulative scans across active threads ordered by lane ID (Table 6.15, page 222):
- `T simd_prefix_inclusive_sum(T data)`: Includes current thread's value.
- `T simd_prefix_exclusive_sum(T data)`: Excludes current thread's value (lane 0 returns 0).
- `T simd_prefix_inclusive_product(T data)`: Includes current thread's value.
- `T simd_prefix_exclusive_product(T data)`: Excludes current thread's value (lane 0 returns 1).

### Broadcast and shuffle functions
Exchanges values between lanes (Table 6.14, pages 218-221):
- `T simd_broadcast(T data, ushort broadcast_lane_id)`: Broadcasts value from specified lane.
- `T simd_broadcast_first(T data)`: Broadcasts value from the lowest active lane.
- `bool simd_is_first()`: Returns true on the lowest active lane in the SIMD group.
- `T simd_shuffle(T data, ushort simd_lane_id)`: Arbitrary cross-lane shuffle.
- `T simd_shuffle_up(T data, ushort delta)`: Shifts data to higher lane IDs by delta without wrapping.
- `T simd_shuffle_down(T data, ushort delta)`: Shifts data to lower lane IDs by delta without wrapping.
- `T simd_shuffle_xor(T data, ushort mask)`: Butterfly exchange across lanes matching XOR mask.
- `T simd_shuffle_and_fill_up(T data, T filling, ushort delta [, ushort modulo])`: Shifts up with wrap-around filling data (pages 223-225). Requires Apple8 or later (Metal Feature Set Tables, page 4).
- `T simd_shuffle_and_fill_down(T data, T filling, ushort delta [, ushort modulo])`: Shifts down with wrap-around filling data. Requires Apple8 or later.

### Quad-group functions
Operates on 4-thread sub-groups (section 6.10.3, pages 226-234):
- Permutes: `quad_broadcast`, `quad_broadcast_first`, `quad_shuffle`, `quad_shuffle_up`, `quad_shuffle_down`, `quad_shuffle_xor`.
- Reductions: `quad_sum`, `quad_product`, `quad_min`, `quad_max`.
- Scans: `quad_prefix_inclusive_sum`, `quad_prefix_exclusive_sum`.
- Votes: `quad_all`, `quad_any`, `quad_ballot` (returns `quad_vote`).

### Hardware availability of SIMD and quad operations
According to the Metal Feature Set Tables (pages 4-5):
- `SIMD barrier`: Apple2+
- `Quad-scoped permute operations`: Apple4+
- `Quad-scoped ballot operation`: Apple6+
- `Quad-scoped reduction operations`: Apple7+
- `SIMD-scoped permute operations`: Apple6+ (macOS Metal 2.1+)
- `SIMD-scoped reduction operations`: Apple7+ (macOS Metal 2.1+)
- `SIMD shift and fill`: Apple8+ (macOS Metal 3+)

### Ballot and vote operations
The ballot operation exists in MSL (section 6.10.2, Table 6.14, pages 218 and 226):
- `simd_vote simd_ballot(bool expr)`: Evaluates `expr` on all active threads. Returns a `simd_vote` bitmask where bit `i` is 1 if lane `i` is active and `expr` evaluated to true. Inactive lanes produce 0.
- `simd_vote simd_active_threads_mask()`: Equivalent to `simd_ballot(true)`. Sets bits of active threads to 1 and inactive threads to 0.
- The `simd_vote` class wraps a private 64-bit integer (`uint64_t v`, section 6.10.2, page 226). On Apple silicon, only the lower 32 bits correspond to physical lanes; the upper 32 bits are undefined.
- Methods on `simd_vote`: `vote.all()` (true if all lanes in the SIMD group set their bit), `vote.any()` (true if at least one valid lane set its bit), and explicit conversion `explicit constexpr operator vote_t() const` where `vote_t` is `uint64_t`.
- `bool simd_all(bool expr)` and `bool simd_any(bool expr)` evaluate Boolean predicates across active threads without constructing a ballot mask. Note difference: `simd_all(expr)` checks all *active* threads, while `simd_ballot(expr).all()` requires that *all* threads in the SIMD group were active and evaluated to true.
- OpenMM maintainer peastman correctly identified that Metal provides a ballot operation. It is available on all Apple silicon chips from M1 upward (Apple7+).

## Atomics

### Atomic data types
MSL provides atomic wrapper types (MSL Spec 4.1, section 2.6, page 39):
- `atomic_int` (alias `atomic<int>`), available on all OS versions since Metal 1.
- `atomic_uint` (alias `atomic<uint>`), available since Metal 1.
- `atomic_bool` (alias `atomic<bool>`), available since Metal 2.4.
- `atomic_ulong` (alias `atomic<ulong>`), available since Metal 2.4.
- `atomic_float` (alias `atomic<float>`), available since Metal 3.

### Atomic float support
Hardware support:
- Metal Feature Set Tables (page 5, row "Floating-point atomics") lists Apple7 as the minimum hardware family for Metal 3 and Metal 4.
- M1 is Apple7, M2 is Apple8, M3 and M4 are Apple9. Therefore, base M2 and M3 both support float atomics under Metal 3 and Metal 4.
Allowed operations (MSL Spec 4.1, section 6.16.4, pages 302-307):
- `atomic_load_explicit`
- `atomic_store_explicit`
- `atomic_exchange_explicit`
- `atomic_compare_exchange_weak_explicit`
- `atomic_fetch_add_explicit` and `atomic_fetch_sub_explicit` (section 6.16.4.5, page 306).
Scope limits:
- Through Metal 4.0, float atomics work only on pointers in the `device` address space.
- Metal 4.1 adds `atomic_float` support for `atomic_fetch_add_explicit` and `atomic_fetch_sub_explicit` in `threadgroup` memory (section 6.16.4.5, page 306).
- Float atomic minimum and maximum do not exist in MSL. Only add, sub, load, store, exchange, and compare-and-swap exist for float.

### 64-bit atomics
Support depends on the exact GPU family and operation (Metal Feature Set Tables, page 5, footnote 7):
- Feature table entry: "64-bit atomics: Metal 3 & 4: Apple9".
- Footnote 7: "GPU devices in the Apple8 family support 64-bit atomic minimum and maximum using ulong, on both buffers and textures, only on macOS. The full set of 64-bit atomic operations is supported on all platforms starting with Apple9."
- MSL operations (section 6.16.4.6, page 307): `void atomic_max_explicit(device atomic_ulong* object, ulong operand, memory_order order)` and `void atomic_min_explicit(...)`. These functions return `void`.
- Full 64-bit atomic arithmetic (`atomic_fetch_add_explicit`, `atomic_fetch_sub_explicit`, `atomic_exchange_explicit`, compare-and-swap on `atomic_ulong`) requires Apple9 (M3 or M4). On base M2 (Apple8), only 64-bit atomic min and max are supported.
- Signed 64-bit atomics (`atomic_long`) do not exist in the MSL standard library. Shaders must use unsigned `atomic_ulong`.

## Integer widths and bit manipulation

### 64-bit integers
- `long` (signed 64-bit integer) and `ulong` / `uint64_t` (unsigned 64-bit integer) are standard scalar types in MSL (section 2.1, Table 2.1, page 25). Both types exist since Metal 2.2 across all operating systems.
- Vector types `long2`, `long3`, `long4`, `ulong2`, `ulong3`, `ulong4` have 8-byte element size and matching alignment (Table 2.3, pages 28-29).
- Buffer usage: Metal supports buffers containing `long` and `ulong` since Metal 2.3 (section 2.8, page 41).
- Hardware 64-bit integer math: Supported on Apple3 and later (Metal Feature Set Tables, page 4).

### Bit manipulation functions
Integer functions in MSL standard library (section 6.4, Table 6.2, pages 202-205):
- `T clz(T x)`: Counts leading zero bits starting at the most significant bit. If `x == 0`, returns the bit width of `T` (32 for uint, 64 for ulong).
- `T ctz(T x)`: Counts trailing zero bits starting at the least significant bit. If `x == 0`, returns the bit width of `T` (behavior defined in MSL 4.1; previously undefined).
- `T popcount(T x)`: Returns the number of non-zero bits in `x`.
- `T reverse_bits(T x)`: Reverses the bit order of `x`. Available on all OS versions since Metal 2.1.
- `deinterleave(Tiu2N v)`: Deinterleaves even and odd bits into a 2-element vector. Added in Metal 4.1 (section 6.4, page 203).

## Precision and math options

### No double precision
MSL Spec 4.1 states explicitly: "Metal does not support the double, long long, unsigned long long, and long double data types." (section 2.1, page 25).
No Apple silicon GPU family provides double-precision floating-point arithmetic. Double precision calculations require fixed-point emulation or twin-float (double-single) algorithms.

### Compile-time math options
Apple controls floating-point optimization via `MTLCompileOptions` (`MTLLibrary.h`, lines 257-338) and compiler flags (MSL Spec 4.1, section 1.6.3-1.6.4, pages 15-16):
1. `mathMode` (`MTLMathMode`, introduced in macOS 15.0 / iOS 18.0; `fastMathEnabled` deprecated in line 326):
   - `MTLMathModeSafe` (`-fmetal-math-mode=safe`): Prevents optimizations that alter numerical results. Preserves IEEE 754 conformance. Sets floating-point contraction to on.
   - `MTLMathModeRelaxed` (`-fmetal-math-mode=relaxed`): Permits aggressive optimizations (reassociation, reciprocal division, fast contraction), but preserves INFs and NaNs. Supported on Apple4 and later.
   - `MTLMathModeFast` (`-fmetal-math-mode=fast`): Default. Assumes no NaNs, no INFs, no signed zeros. Reassociation and reciprocal approximation enabled.
2. `mathFloatingPointFunctions` (`MTLMathFloatingPointFunctions`, `MTLLibrary.h`, line 338):
   - `MTLMathFloatingPointFunctionsFast` (`-fmetal-math-fp32-functions=fast`): Default. Directs single-precision math calls to the `metal::fast` namespace.
   - `MTLMathFloatingPointFunctionsPrecise` (`-fmetal-math-fp32-functions=precise`): Directs calls to the `metal::precise` namespace.
3. Contraction control: `-ffp-contract=off` disables fused multiply-add generation (section 1.6.4, page 16).
4. Rounding control: Metal 4.1 adds `MTLFloatingPointConversionRoundingMode` (`MTLLibrary.h`, lines 293-305) with options `ToNearestEven` (default) and `TowardZero` (`-fmetal-float-rounding-mode=rtz`).
5. Source pragma: `#pragma METAL fp math_mode(relaxed | safe | fast)` configures floating-point semantics for specific source code blocks.

## Kernel specialization without recompilation

1. Function constants:
   - Annotated in MSL with `constant Type name [[function_constant(id)]];` (section 5.8, pages 190-196).
   - Up to 65,536 function constants per pipeline state (Metal Feature Set Tables, page 7).
   - Host code sets values via `MTLFunctionConstantValues` during `newComputePipelineStateWithDescriptor:error:`.
   - The compiler folds branches, unrolls loops, and eliminates dead code without re-parsing the original MSL source text.
2. Visible functions:
   - Marked with `[[visible]]` (section 5.1.4, page 128).
   - Callable through function pointers stored in an `MTLVisibleFunctionTable` (section 2.15, page 59).
   - Supported in compute pipelines on Apple6 and later (Metal Feature Set Tables, page 5).
3. Dynamic libraries:
   - Compiled with `MTLLibraryTypeDynamic` (`MTLLibrary.h`, line 353). Represented on host by `MTLDynamicLibrary`.
   - Compiles external functions into precompiled Metal IR that link against pipelines via `MTLLinkedFunctions`. Supported on Apple6 and later (Metal Feature Set Tables, page 4).
4. Function stitching:
   - Marked with `[[stitchable]]` (section 5.1.5, page 128).
   - Host generates an `MTLFunctionStitchingGraph` that assembles modular shader functions into a single compiled pipeline without textual source concatenation.

## Runtime compilation cost and shader caching

- Online source compilation via `device->newLibraryWithSource(...)` invokes Clang and LLVM frontends on the CPU. This call costs tens to hundreds of milliseconds per source string.
- Operating system cache: Metal automatically writes compiled GPU binaries to `~/Library/Caches/com.apple.metal/`. Subsequent compilations with identical source and compile options hit the on-disk cache.
- `MTLBinaryArchive`: Supported on Apple3 and later (Metal Feature Set Tables, page 5). The application explicitly serializes compiled pipeline binaries into a file on disk. On startup, `MTLComputePipelineDescriptor.binaryArchives` loads the precompiled GPU machine code directly, eliminating runtime LLVM compilation.
- In Metal 4, `MTL4Archive` (`MTL4Archive.h`, line 49) and `MTL4Compiler` (`MTL4Compiler.h`, line 45) manage pipeline caching with asynchronous compilation tasks.

## Pointers inside structs and pointer arithmetic

1. Pointers inside structs:
   - In ordinary MSL structures, pointer members are permitted but must declare their target address space explicitly (`device float* ptr;`).
   - Tier 2 argument buffers fully support nested resource pointers (`constant Resources*`, `device float*`, `texture2d<float>`) within structs (section 2.13.1, pages 56-57).
2. Pointer arithmetic limits:
   - Standard C++ pointer arithmetic is legal within the bounds of a allocated buffer object.
   - Pointers cannot cross address space boundaries. Casting a pointer between different address spaces (`threadgroup` to `device`) is undefined behavior and rejected by the compiler.
   - Metal 3 and later expose 64-bit GPU virtual addresses via `buffer.gpuAddress` (`MTLGPUAddress.h`, line 19; `MTLBuffer.h`, line 124). Pointers in argument tables can be populated via these 64-bit integer virtual addresses (`setAddress:atIndex:`).

## What changed in the two newest versions

### Metal 4.0 (macOS 26, June 2025)
- C++17 base: Upgraded MSL base language specification from C++14 to C++17 (MSL Spec 4.1, section 1.5, page 12).
- Tensors: Introduced native `tensor` types and math operations (section 2.22, pages 74-111).
- Metal Performance Primitives: Added matrix multiply operations in `metal_performance_primitives` (section 7, pages 326-369).
- User annotations: Added `[[user_annotation("...")]]` attribute on functions (section 5.1.12, page 132).
- Sampler features: Added LOD bias and min/max reduction sampler modes (section 2.10, page 49).
- Cube texture atomics: Added atomic operations for cube and cube-array textures (section 6.13.6-6.13.7, pages 284-288).
- Intersection function buffers: Added buffer support to ray tracing intersection functions (section 2.17.1, page 61).
- Integer packing: Added packing and unpacking for `snorm10a2` format (section 6.15, page 297).

### Metal 4.1 (macOS 27, June 2026)
- Placement new: Added support for placement `new` operator (section 1.5.4, page 13, and section 6.2, page 197).
- Float rounding mode: Added compiler option to set rounding toward zero for float-to-float conversions (section 1.6.3, page 15).
- Memory order on barriers and atomics: Added acquire and release memory order semantics to threadgroup and device barriers and atomic operations (sections 6.10, 6.16.1.2, and 6.16.4, pages 216, 301, 305).
- Threadgroup float atomics: Added `atomic_float` support for `atomic_fetch_add_explicit` and `atomic_fetch_sub_explicit` in `threadgroup` memory (section 6.16.4.5, page 306).
- Bit deinterleaving: Added `deinterleave` and `interleave` built-in integer functions (section 6.4, page 203).
- Multiplane tensors: Added block-scaling support to tensors (`tensor_blockwise`, section 2.22).
- Texture reading: Added clamp-to-edge reads and multi-pixel texture reads (section 6.13, pages 249-251).

## Consequences for an OpenMM Metal platform

1. The 31-buffer argument limit is easily reached by complex OpenMM kernels (e.g., nonbonded force kernels requiring coordinates, forces, charges, Lennard-Jones parameters, exclusion lists, periodic box vectors, energy accumulators, and parameter offsets). The platform must either use argument buffers (Tier 2, supported across all Apple silicon) or pack uniform arrays into structures.
2. Single-precision floating-point is the only available hardware float format. The platform cannot use native `double` for accumulation. It must implement 64-bit fixed-point integer accumulation (`long` / `int64_t` in buffers and atomics) or double-single arithmetic, exactly as OpenMM's OpenCL and CUDA platforms do for mixed-precision modes.
3. Base M2 supports `atomic_float` in device memory for single-precision addition. This enables direct float atomics for `gridSpreadCharge` in PME on M2 and M3.
4. Base M2 (Apple8) does not support 64-bit atomic addition (`atomic_fetch_add_explicit` on `ulong`). It only supports 64-bit atomic min and max. Therefore, 64-bit fixed-point force accumulation on M2 cannot use 64-bit atomic add instructions. The kernel must accumulate forces within SIMD groups or threadgroups using `simd_sum` and write them out via 32-bit atomic pairs, CAS loops, or partitioned buffer writes. M3 and later (Apple9) have the full 64-bit atomic add instruction.
5. The presence of `simd_ballot` and `clz` / `ctz` on Apple silicon enables a fast `findBlocksWithInteractions` kernel. Lanes can evaluate bounding box overlaps, construct a 32-bit lane bitmask via `simd_ballot(overlap).all()` or `(uint32_t)(vote_t)simd_ballot(overlap)`, and pop interaction indices with `ctz` without memory traffic.
6. SIMD shuffle instructions (`simd_shuffle_down`, `simd_shuffle_xor`) allow neighbor-list tile reductions in `computeNonbonded` across 32-thread warps without using threadgroup memory or threadgroup barriers.
7. Shaders must compile with `-fmetal-math-mode=safe` or `-fmetal-math-mode=relaxed` for MD integration loops. Default fast-math mode (`-fmetal-math-mode=fast`) treats NaNs and INFs as impossible, which breaks numerical checks and stability detection in MD trajectories.
8. Function constants (`[[function_constant]]`) provide the cleanest mechanism to specialize nonbonded kernels (switching between cutoff types, periodic boundary conditions, and PME exclusions) without paying the overhead of runtime source-string recompilation.

# OpenMM Common Compute Metal Kernel Census

## Question

Can OpenMM Common Compute kernels (`platforms/common/src/kernels/*.cc`, exactly 67 files) compile directly as Metal Shading Language (MSL) behind a compatibility macro prelude and mechanical rewriting, and what specifically blocks the rest?

## Method

An automated census harness (`census.swift`, executed via `run.sh`) invokes the native Apple Metal runtime compiler (`MTLDevice.makeLibrary(source:options:)`) on all 67 kernel source files from the OpenMM repository checkout (`platforms/common/src/kernels/`).

The harness evaluates each file against two components:
1. Macro prelude (`prelude.metal`): Header containing type definitions, address space mappings, math polyfills, atomics, warp shuffle intrinsics, and program-scope thread coordinate builtins.
2. Mechanical signature rewriter: Rewrites kernel function declarations to comply with MSL input parameter address space rules without altering kernel algorithm code.

### Prelude Architecture

- Address spaces: Maps OpenCL/CUDA spaces to Metal (`DEVICE` to empty/inline, `GLOBAL` to `device`, `LOCAL` to `threadgroup`, `LOCAL_ARG` to `threadgroup`).
- Keyword isolation: MSL reserves `thread` as an address-space qualifier keyword. OpenMM kernels declare local variables named `thread`. Defining `#define thread _mm_thread` after importing `<metal_stdlib>` resolves all collisions.
- Program-scope thread coordinates: MSL allows module-scope global declarations decorated with attribute qualifiers. Declaring `uint3 _metal_thread_pos_grid [[thread_position_in_grid]];` and equivalent builtins at module scope allows `GLOBAL_ID`, `LOCAL_ID`, `GROUP_ID`, `GLOBAL_SIZE`, `LOCAL_SIZE`, and `NUM_GROUPS` to remain zero-argument macros. Thread coordinates do not need to be injected into kernel parameter lists.
- Atomics: Implements 32-bit `int` and `uint` atomics using `atomic_fetch_add_explicit`. Implements 64-bit integer atomics via split 32-bit high/low word addition with carry detection. Implements `float` atomic addition via `atomic_compare_exchange_weak_explicit` loops on bit-cast integer words.
- Standard math: Provides Abramowitz and Stegun polynomial approximations for `erf` and `erfc` (absent from MSL standard library). Adds an overload for `cross(float4, float4)` matching OpenCL vector semantics.
- Warp intrinsics: Maps CUDA `__shfl`, `__shfl_down`, and `__shfl_xor` to Metal `simd_shuffle`, `simd_shuffle_down`, and `simd_shuffle_xor`. Maps `__ffs` to `ctz`.

### Mechanical Rewrite Rules

Metal Shading Language specification disallows unadorned pass-by-value parameters in kernel signatures (`invalid type 'thread T' for input declaration`). MSL requires all kernel arguments to reside in `device`, `constant`, or `threadgroup` address spaces, or use attribute qualifiers.

The mechanical rewriter applies the following rules:
1. Entry point qualifier: Converts `KERNEL void name(...)` to `kernel void name(...)`.
2. Pointer parameters: Leaves parameters with pointer types (`*`) intact without `[[buffer(n)]]` attributes. The Metal compiler automatically assigns sequential buffer bindings to unadorned pointer arguments starting at index 0.
3. Value parameters: Rewrites scalar and struct value parameters `T name` to `constant T& _in_name`.
4. Local mutable copies: Inserts `T name = _in_name;` as the first line of the kernel function body. This preserves mutability of by-value parameters within the kernel body without editing downstream kernel code.
5. Conditional compilation: Preserves preprocessor directives (`#ifdef`, `#else`, `#endif`) nested within parameter lists and mirrors them in the generated local copy assignments.

### Host Substitutions

OpenMM host C++ classes (`platforms/common/src/*.cpp`) interpolate macros into kernel strings at compile time before dispatching to OpenCL or CUDA. The census provides standard defaults matching OpenMM runtime behavior (for example, `TILE_SIZE 32`, `WARP_SIZE 32`, `NUM_ATOMS 1000`). Files with custom placeholders (`PARAMETER_ARGUMENTS`, `COMPUTE_FORCE`, `EXTRA_ARGS`) receive empty or minimal structural stubs matching host driver substitution points.

## Results

- Total kernel source files evaluated: 67
- Compiled with zero errors: 49 (73.1%)
- Failed compilation: 18 (26.9%)

Structured machine-readable results are stored in `census.json`. Tabular per-file results are stored in `census.md`.

### Breakdown

- Full kernel files: All 48 files containing `KERNEL void` entry points compiled with zero errors.
- Standalone helper files: 1 file (`pointFunctions.cc`) contains inline helper functions and compiled with zero errors.
- Failed files: Exactly 18 files failed compilation. All 18 failed with the same root cause: `code_snippet_missing_function`.

The 18 failed files are:
1. `angleForce.cc`
2. `bondForce.cc`
3. `cmapTorsionForce.cc`
4. `constantPotentialCoulombEnergyForces.cc`
5. `constantPotentialExceptions.cc`
6. `constantPotentialExclusions.cc`
7. `coulombLennardJones.cc`
8. `customExternalForce.cc`
9. `customGBChainRule.cc`
10. `customNonbonded.cc`
11. `gbsaObc2.cc`
12. `harmonicAngleForce.cc`
13. `harmonicBondForce.cc`
14. `nonbondedExceptions.cc`
15. `periodicTorsionForce.cc`
16. `pmeExclusions.cc`
17. `rbTorsionForce.cc`
18. `torsionForce.cc`

## Three Findings for an OpenMM Maintainer

### 1. Standalone Common Kernels Compile Without Code Changes

Every single complete kernel file in `platforms/common/src/kernels/` (48 out of 48) compiles as MSL under the macro prelude and mechanical parameter rewriting. The 18 failing files are not invalid kernels; they are raw algorithmic code fragments without enclosing function headers or kernel declarations. OpenMM host classes (`BondedUtilities.cpp`, `CommonCalcNonbondedForce.cpp`, `CommonKernels.cpp`) textually splice these snippets into master kernel templates at runtime. To make them compile standalone, upstream would need to encapsulate each fragment into a callable `DEVICE` inline function.

### 2. Program-Scope Globals Eliminate Thread Parameter Plumbing

MSL 2.0+ supports program-scope global variables with built-in attribute qualifiers. Declaring `uint3 _metal_thread_pos_grid [[thread_position_in_grid]];` at global scope allows macros like `GLOBAL_ID` (`_metal_thread_pos_grid.x`) to evaluate cleanly anywhere in the compilation unit. Thread coordinates do not need to be passed into kernel signatures or forwarded through helper call stacks. This keeps OpenMM Common kernel signatures identical across OpenCL, CUDA, HIP, and Metal.

### 3. Buffer Attributes Are Optional; Value Arguments Need Address Space

Metal does not require manual `[[buffer(n)]]` index assignments on pointer parameters. The runtime compiler assigns binding slots automatically. However, Metal strictly rejects unadorned value parameters in kernel signatures. Passing scalars and structs by const reference (`constant T& _in_arg`) combined with a function-entry local copy (`T arg = _in_arg;`) completely resolves this restriction with zero changes to existing kernel bodies.

## Reproduction

Run the census on macOS:

```bash
./run.sh
```

The script compiles `census.swift` with `swiftc` and executes `./census`, validating all 67 files against the system Metal compiler.

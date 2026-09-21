# Real OpenMM program Metal census

## Question

Can the complete GPU program set compiled by real OpenMM simulations (ApoA1 RF and ApoA1 PME benchmarks) compile as Metal Shading Language by changing only the platform prelude and applying mechanical build-time rewrites, and what blocks the remainder?

## Method

The OpenCL platform of OpenMM was patched on an Apple M2 to dump every program compiled during execution of the ApoA1 RF and ApoA1 PME benchmarks.
The dump captured 26 complete programs (12 for RF, 14 for PME) across three files per program:
1. `NNN.body.cl`: the kernel body after host macro splicing and template interpolation.
2. `NNN.defines`: tab-separated table of platform context defines and program-specific defines.
3. `NNN.full.cl`: the exact source text compiled by OpenCL runtime driver.

An automated Swift harness (`census.swift`, executed via `run.sh`) constructs the Metal equivalent of each program.
The harness replaces context defines and `common.cl` with a static Metal prelude (`prelude.metal`), preserves program-specific defines, and applies two mechanical rewrite rules to the body text:
1. `kernel_signature_value_parameters`: converts unadorned by-value scalar and struct parameters `T name` in kernel declarations to `constant T& _in_name` and emits a function-entry local mutable copy `T name = _in_name;`.
2. `vector_literal_constructor`: converts OpenCL cast-style vector literals `(type)(...)` to C++ function-style constructor calls `type(...)`.

The harness invokes `MTLDevice.makeLibrary(source:options:)` on every program.
For each kernel found in the compiled library, the harness builds a compute pipeline state with `MTLDevice.makeComputePipelineState(function:)`.
The harness checks whether each program depends on 64-bit integer atomics by compiling against both a complete prelude and a prelude with 64-bit atomics disabled.
The evaluation ran on two physical Apple Silicon machines:
1. Local host: Apple M3 Ultra (macOS 27.0).
2. Remote host: Apple M2 Mac mini (macOS 27.0) via `mini.sh`.

## Result

Every program in both benchmarks compiled and created compute pipeline states for all kernels.
The compilation and pipeline creation pass rates were identical on Apple M3 Ultra and Apple M2.

| Benchmark test | Total programs | Compiled clean | Compiles with unsafe placeholder | Failed | Effective compilation rate |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `apoa1rf` | 12 | 10 (83.3%) | 2 (16.7%) | 0 (0.0%) | 100.0% |
| `apoa1pme` | 14 | 11 (78.6%) | 3 (21.4%) | 0 (0.0%) | 100.0% |
| **Total** | **26** | **21 (80.8%)** | **5 (19.2%)** | **0 (0.0%)** | **100.0%** |

The 5 programs requiring the unsafe 64-bit atomic placeholder are:
- `apoa1rf/006`: `computeBondedForces` (buffer `forceBuffer`)
- `apoa1rf/010`: `computeNonbonded` (buffer `forceBuffers`)
- `apoa1pme/007`: `computeBondedForces` (buffer `forceBuffer`)
- `apoa1pme/011`: `gridSpreadCharge` in PME (buffer `pmeGrid`)
- `apoa1pme/012`: `computeNonbonded` (buffer `forceBuffers`)

Machine-readable records are in `census.json`.
Tabular breakdowns, rewrite metrics, and root-cause analyses are in `census.md`.

## Three findings that matter most to a maintainer

### 1. Zero kernel code changes needed apart from signature passing and vector casts

All 26 real GPU programs compile and build compute pipeline states under Metal without modifying kernel algorithms or control flow.
Program-scope thread builtins (`[[thread_position_in_grid]]`) eliminate all thread parameter plumbing across helper call trees.
OpenCL address space keywords (`__global`, `__local`, `restrict`), barrier primitives (`barrier(CLK_LOCAL_MEM_FENCE)`), math functions, and 32-bit atomics (`atom_inc`, `atom_add`) resolve entirely in a single static header (`prelude.metal`).
Only two mechanical text transforms are required at program build time: rewriting kernel value parameters to const references (338 sites), and converting vector cast syntax to constructor calls (52 sites).

### 2. Lack of native 64-bit atomics is the only hardware blocker

Apple Silicon GPUs do not provide native 64-bit integer atomics (`atomic<ulong>`).
Exactly 5 programs across the two benchmarks depend on 64-bit atomic additions into fixed-point accumulation buffers.
These programs accumulate forces in bonded force calculation (`forceBuffer`), nonbonded interaction calculation (`forceBuffers`), and charge spreading on the PME mesh (`pmeGrid`).
The split-word 32-bit atomic add emulation allows these programs to compile and build pipelines, but is unsafe under thread contention.
Production deployment requires upstream to route these buffers through single-precision float atomics (supported on M2 and M3) or threadgroup/SIMD reduction buffers.

### 3. OpenCL vector cast syntax causes silent data corruption without rewriting

In OpenCL C, `(real4)(a, b, c, d)` constructs a four-component vector.
In C++ and Metal Shading Language, `(real4)` is a C-style cast applied to a parenthesized expression containing commas.
The C++ comma operator evaluates `a`, `b`, `c`, and `d` in sequence, discards `a`, `b`, and `c`, and evaluates to scalar `d`.
MSL then calls the broadcast constructor `float4(d)`, producing `float4(d, d, d, d)`.
This construct compiles without warnings or errors, but silently replaces particle positions and displacement vectors with repeated scalar coordinates.
Rewriting `\(\s*(real4|float4|float2)\s*\)\s*\(` to `$1(` invokes the genuine multi-argument vector constructor and prevents silent numerical corruption.

# Real OpenMM program Metal census

## Execution environment and hardware chips

- Current test device: Apple M3 Ultra
- Target devices evaluated: Apple M3 Ultra and Apple M2 (Mac mini)
- Verification method: runtime compilation with `MTLDevice.makeLibrary(source:options:)` followed by compute pipeline state creation for every kernel.

## Program totals by test

| Benchmark test | Total programs | Compiled clean | Compiles with unsafe placeholder | Failed | Effective compilation rate |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `apoa1rf` | 12 | 10 | 2 | 0 | 100.0% |
| `apoa1pme` | 14 | 11 | 3 | 0 | 100.0% |
| **Total** | **26** | **21** | **5** | **0** | **100.0%** |

## Documented mechanical rewrite rules

| Rule name | Pattern | Replacement | Sites touched | Meaning preservation rationale |
| :--- | :--- | :--- | :--- | :--- |
| `kernel_signature_value_parameters` | `(?:KERNEL\|__kernel)\s+void\s+(\w+)\s*\(([\s\S]*?)\)\s*\{` | `kernel void $1(<rewritten>) { <local_copies> }` | 338 | Semantics preserved identically. Passing by const reference and immediately making a local value copy guarantees identical variable scope and mutability as OpenCL pass-by-value. |
| `vector_literal_constructor` | `\(\s*(real4\|float8\|float4\|float2\|float3\|int2\|int3\|int4\|uint2\|uint3\|uint4\|short2\|short3\|short4)\s*\)\s*\(` | `$1(` | 52 | Required to preserve meaning. Without this rewrite, OpenCL vector literals like (real4)(x, y, z, w) silently degenerate to float4(w, w, w, w) in MSL due to C++ comma operator rules. The rewrite invokes the intended 4-component constructor. |

## Root cause categories and judgements

| Category | Mechanism | Affected programs | Judgement |
| :--- | :--- | :--- | :--- |
| `kernel_signature_value_parameters` | MSL prohibits unadorned pass-by-value parameters in kernel signatures (`invalid type 'thread T' for input declaration`). | All 26 programs (338 parameter sites) | Fixable by mechanical rewrite: converts to `constant T& _in_param` and introduces local value copy `T param = _in_param;` at kernel entry. |
| `opencl_vector_literal_cast` | OpenCL C allows `(type)(a, b, c, d)`. In C++/MSL, `(type)(...)` evaluates the inner expression with comma operator, discarding earlier components and passing only the last component to a broadcast constructor. | `apoa1rf` 000, 010, 011; `apoa1pme` 000, 012, 013 (52 sites total) | Fixable by mechanical rewrite: converts `(type)(` to `type(`. Essential for numerical meaning. |
| `opencl_address_spaces_and_keywords` | Raw OpenCL files contain `__kernel`, `__global`, `__local`, `__constant`, `restrict`. | 11 programs in `apoa1rf` and 11 in `apoa1pme` | Fixable in prelude: `#define` mappings to Metal equivalents (`device`, `threadgroup`, `constant`, `kernel`). |
| `opencl_barriers` | Raw OpenCL files call `barrier(CLK_LOCAL_MEM_FENCE)` or `barrier(CLK_LOCAL_MEM_FENCE+CLK_GLOBAL_MEM_FENCE)`. | Sort (007/004/008) and findBlocksWithInteractions (009/010) | Fixable in prelude: inline wrapper mapping to `threadgroup_barrier`. |
| `opencl_atomic_inc_dec` | OpenCL sort kernels call `atom_inc` on `uint*`. MSL standard library lacks `atom_inc`. | Sort (007 in rf; 004, 008 in pme) | Fixable in prelude: inline wrappers around `atomic_fetch_add_explicit`. |
| `opencl_8element_vector` | `determineNativeAccuracy` in 000 uses `float8`, which is absent from MSL and collides with internal reservation. | 000 in `apoa1rf` and `apoa1pme` | Fixable in prelude: custom `_openmm_float8` struct with component fields `.s0` through `.s7` and constructor. |
| `64bit_integer_atomics` | Apple Silicon GPUs do not provide native 64-bit integer atomics (`atomic<ulong>`). Programs accumulating forces into 64-bit fixed point buffers require atomic updates. | `apoa1rf`: 006 (bonded), 010 (nonbonded); `apoa1pme`: 007 (bonded), 011 (PME charge spreading), 012 (nonbonded) | Hard Metal limit: compiles with unsafe split-word atomic placeholder, but requires upstream architectural redesign (float atomics or SIMD group reduction buffers) for production safety. |

## Key programs: computeNonbonded and findBlocksWithInteractions

### computeNonbonded (`apoa1rf` 010, 011; `apoa1pme` 012, 013)

- Programs 010 (rf) and 012 (pme) compute nonbonded forces and energies (`INCLUDE_FORCES 1`). Programs 011 (rf) and 013 (pme) compute nonbonded energy only (`INCLUDE_ENERGY 1`).
- What it took to compile:
  1. Keyword and address space mapping: `__kernel`, `__global`, and `restrict` handled by `prelude.metal`.
  2. Program-scope builtins: Thread coordinates (`GLOBAL_ID`, `LOCAL_ID`, `GROUP_ID`) resolved via module-scope Metal attributes without modifying function call trees.
  3. Mechanical parameter rewrite: Rewrote 8 by-value arguments (`periodicBoxSize`, `invPeriodicBoxSize`, box vectors, tile limits) to const references with function-entry local copies.
  4. Vector literal rewrite: Exactly 12 sites of `(real4)(` and `(float2)(` rewritten to `real4(` and `float2(`. Without this rewrite, C++ comma evaluation would discard `x, y, z` coordinates and broadcast scalar `w` into all fields.
  5. 64-bit atomics: Force accumulation in 010 and 012 writes to `forceBuffers` via `ATOMIC_ADD(&forceBuffers[...], (mm_ulong) realToFixedPoint(...))`. This compiles under the split-word unsafe placeholder. Status: `compiles with unsafe placeholder` (kernel `computeNonbonded`, buffer `forceBuffers`).
  6. Energy evaluation: Programs 011 and 013 accumulate energy without atomics (`energyBuffer[GLOBAL_ID] += energy;`) and compile cleanly without placeholders. Status: `compiled`.

### findBlocksWithInteractions (`apoa1rf` 009; `apoa1pme` 010)

- Finds neighbor blocks with non-zero interactions and builds neighbor lists.
- What it took to compile:
  1. Preprocessor branching: The program specifies `program SIMD_WIDTH 32`. The `#if SIMD_WIDTH <= 32` path compiles using 32-thread SIMD logic, skipping the wide-SIMD `#else` branch.
  2. Atomics: All atomic operations in `findBlocksWithInteractions` target `interactionCount` (`device uint*`), which is a 32-bit unsigned integer. MSL compiles this directly to hardware 32-bit `atomic_fetch_add_explicit`. No 64-bit atomics are used.
  3. Memory barriers: Exactly 21 calls to `barrier(CLK_LOCAL_MEM_FENCE)` map cleanly to `threadgroup_barrier(mem_flags::mem_threadgroup)`.
  4. Mechanical parameter rewrite: Rewrote 29 scalar/struct parameters across the 4 compiled kernels (`findBlockBounds`, `computeSortKeys`, `sortBoxData`, `findBlocksWithInteractions`).
  5. Status: `compiled` cleanly with zero errors and zero unsafe placeholders.

## Cross-chip validation: Apple M3 Ultra and Apple M2

Both chips executed the census via runtime `MTLDevice.makeLibrary` and pipeline creation:

| Chip | Total programs | Compiled clean | Compiles with unsafe placeholder | Failed | Status |
| :--- | :--- | :--- | :--- | :--- | :--- |
| Apple M3 Ultra | 26 | 21 | 5 | 0 | 100.0% pipeline state creation |
| Apple M2 (Mac mini) | 26 | 21 | 5 | 0 | 100.0% pipeline state creation |

Kernel compilation and pipeline creation behavior is identical across both chips. The same 5 programs require the 64-bit atomic placeholder on both architectures.

## Per-program compilation details

| Test | Index | Status | Kernels | Rewrite sites (Sig / Vec) | Unsafe placeholder target |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `apoa1rf` | `000` | **compiled** | determineNativeAccuracy, reduceForces, reduceReal4Buffer | 5 / 2 | - |
| `apoa1rf` | `001` | **compiled** | clearBuffer, clearFiveBuffers, clearFourBuffers, clearSixBuffers, clearThreeBuffers, clearTwoBuffers, reduceEnergy, setCharges | 24 / 0 | - |
| `apoa1rf` | `002` | **compiled** | applySettleToPositions, applySettleToVelocities, applyShakeToPositions, applyShakeToVelocities, computeCCMAConstraintDirectionsKernel, computeCCMAPositionConstraintForceKernel, computeCCMAVelocityConstraintForceKernel, computeKineticEnergy, computeVirtualSites, distributeVirtualSiteForces, generateRandomNumbers, multiplyByCCMAConstraintMatrixKernel, runCCMA, saveDistributedForces, timeShiftVelocities, updateCCMAAtomPositionsKernel | 32 / 0 | - |
| `apoa1rf` | `003` | **compiled** | copyFloatBuffer | 2 / 0 | - |
| `apoa1rf` | `004` | **compiled** | computeExclusionParameters, computeParameters, computePlasmaCorrection | 6 / 0 | - |
| `apoa1rf` | `005` | **compiled** | calcCenterOfMassMomentum, removeCenterOfMassMomentum | 2 / 0 | - |
| `apoa1rf` | `006` | **compiles with unsafe placeholder** | computeBondedForces | 6 / 0 | `computeBondedForces:forceBuffer` |
| `apoa1rf` | `007` | **compiled** | assignElementsToBuckets, assignElementsToBuckets2, computeBucketPositions, computeRange, copyDataToBuckets, sortBuckets, sortShortList, sortShortList2 | 11 / 0 | - |
| `apoa1rf` | `008` | **compiled** | integrateLangevinMiddlePart1, integrateLangevinMiddlePart2, integrateLangevinMiddlePart3, selectLangevinStepSize | 11 / 0 | - |
| `apoa1rf` | `009` | **compiled** | computeSortKeys, findBlockBounds, findBlocksWithInteractions, sortBoxData | 29 / 0 | - |
| `apoa1rf` | `010` | **compiles with unsafe placeholder** | computeNonbonded | 8 / 12 | `computeNonbonded:forceBuffers` |
| `apoa1rf` | `011` | **compiled** | computeNonbonded | 8 / 12 | - |
| `apoa1pme` | `000` | **compiled** | determineNativeAccuracy, reduceForces, reduceReal4Buffer | 5 / 2 | - |
| `apoa1pme` | `001` | **compiled** | clearBuffer, clearFiveBuffers, clearFourBuffers, clearSixBuffers, clearThreeBuffers, clearTwoBuffers, reduceEnergy, setCharges | 24 / 0 | - |
| `apoa1pme` | `002` | **compiled** | applySettleToPositions, applySettleToVelocities, applyShakeToPositions, applyShakeToVelocities, computeCCMAConstraintDirectionsKernel, computeCCMAPositionConstraintForceKernel, computeCCMAVelocityConstraintForceKernel, computeKineticEnergy, computeVirtualSites, distributeVirtualSiteForces, generateRandomNumbers, multiplyByCCMAConstraintMatrixKernel, runCCMA, saveDistributedForces, timeShiftVelocities, updateCCMAAtomPositionsKernel | 32 / 0 | - |
| `apoa1pme` | `003` | **compiled** | copyFloatBuffer | 2 / 0 | - |
| `apoa1pme` | `004` | **compiled** | assignElementsToBuckets, assignElementsToBuckets2, computeBucketPositions, computeRange, copyDataToBuckets, sortBuckets, sortShortList, sortShortList2 | 11 / 0 | - |
| `apoa1pme` | `005` | **compiled** | computeExclusionParameters, computeParameters, computePlasmaCorrection | 6 / 0 | - |
| `apoa1pme` | `006` | **compiled** | calcCenterOfMassMomentum, removeCenterOfMassMomentum | 2 / 0 | - |
| `apoa1pme` | `007` | **compiles with unsafe placeholder** | computeBondedForces | 6 / 0 | `computeBondedForces:forceBuffer` |
| `apoa1pme` | `008` | **compiled** | assignElementsToBuckets, assignElementsToBuckets2, computeBucketPositions, computeRange, copyDataToBuckets, sortBuckets, sortShortList, sortShortList2 | 11 / 0 | - |
| `apoa1pme` | `009` | **compiled** | integrateLangevinMiddlePart1, integrateLangevinMiddlePart2, integrateLangevinMiddlePart3, selectLangevinStepSize | 11 / 0 | - |
| `apoa1pme` | `010` | **compiled** | computeSortKeys, findBlockBounds, findBlocksWithInteractions, sortBoxData | 29 / 0 | - |
| `apoa1pme` | `011` | **compiles with unsafe placeholder** | addEnergy, addForces, findAtomGridIndex, finishSpreadCharge, gridEvaluateEnergy, gridInterpolateChargeDerivatives, gridInterpolateForce, gridSpreadCharge, reciprocalConvolution | 39 / 0 | `gridSpreadCharge:pmeGrid` |
| `apoa1pme` | `012` | **compiles with unsafe placeholder** | computeNonbonded | 8 / 12 | `computeNonbonded:forceBuffers` |
| `apoa1pme` | `013` | **compiled** | computeNonbonded | 8 / 12 | - |

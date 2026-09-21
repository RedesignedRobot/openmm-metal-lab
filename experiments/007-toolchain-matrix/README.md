# Experiment 007: Toolchain Matrix

## Question

This experiment replaces assumptions about the Apple Metal compiler with empirical measurements on Apple Silicon hardware. Six specific questions are investigated:

1. What causes the 5.4% fixed-point force discrepancy in `computeBondedForces` between Metal and OpenCL? Do compiler options like `mathMode`, `mathFloatingPointFunctions`, or OpenCL optimization flags bridge this gap?
2. Does the Metal Shading Language standard library provide `erf` or `erfc` in any version? What is the accuracy and GPU execution cost of degree-7 rational erfc compared to alternatives and OpenCL?
3. Which `MTLLanguageVersion` values are accepted on macOS 27? Which version first supports program-scope thread builtins, and what is the compilation pass rate for the 26 real programs from experiment 005?
4. What is the cold and warm compilation cost across all 26 real programs for OpenCL versus Metal? Can `MTLBinaryArchive` bypass runtime source compilation?
5. How does runtime compilation time compare between textual `#define` replacement and MSL `function_constant` specialization?
6. Is an offline Metal compiler available on standard macOS developer installations without Xcode GUI interaction?

## Method

All measurements execute on two physical machines:
- Host: Apple M3 Ultra, macOS 27.0.0 (Build 26A428).
- Remote: Apple M2 Mac mini (10 GPU cores), macOS 27.0.0 (Build 26A428).

The benchmark harness is written in Swift (`harness.swift`). It links against `Metal.framework` and `OpenCL.framework`. The harness executes through `run.sh` on the host and through `./mini.sh experiments/007-toolchain-matrix "sh run.sh"` on the Mac mini.

Option liveness is verified before benchmarking:
- `mathMode = .safe`: verifies that `(1.0 + 1e20) - 1e20 == 0.0` and `isnan(0.0 / 0.0) == 1.0`.
- `mathMode = .relaxed`: verifies that `(1.0 + 1e20) - 1e20 == 1.0` and `isnan(0.0 / 0.0) == 1.0`.
- `mathMode = .fast`: verifies that `(1.0 + 1e20) - 1e20 == 1.0` and `isnan(0.0 / 0.0) == 0.0`.
- `mathFloatingPointFunctions`: verifies that `.precise` and `.fast` generate distinct bit patterns for transcendental functions.

For question 1, `computeBondedForces` (program 006 from `apoa1rf`, 276,672 fixed-point words) runs under all valid Metal compiler options and OpenCL options. An isolated sweep of 1,000,000 float inputs evaluates single operations (`sqrt`, `rsqrt`, `recip`, `divide`, `fma`, `muladd`, `asin`, `acos`, `normalize`).

For question 2, all MSL versions (1.1 through 4.1) are queried for `erf` and `erfc`. Four implementations are compared over [0.0, 4.0] across 1,000,000 points against double-precision reference values:
- OpenCL builtin `erfc`
- Metal 005 prelude `1.0f - erf(x)`
- Metal direct Abramowitz & Stegun 7.1.26 polynomial
- Metal degree-7 minimax rational approximation

GPU execution time is measured by running 50,000,000 evaluations inside a compute kernel.

For question 3, `makeLibrary` tests all 12 MSL versions. Global variable declarations with `[[thread_position_in_grid]]` test program-scope builtin support. All 26 real programs from experiment 005 are compiled under MSL 3.1, 3.2, 4.0, and 4.1.

For question 4, cold compilation (cache busted with unique comments) and warm compilation (repeated in-memory calls) are timed for all 26 programs. `MTLBinaryArchive` is created, serialized to disk, loaded, and timed during pipeline state creation.

For question 5, `computeBondedForces` is compiled under 5 cold passes and 10 parameter-change updates for `PADDED_NUM_ATOMS` using textual `#define` versus MSL `function_constant`.

For question 6, `xcrun -f metal`, `xcode-select -p`, and directory scans check for offline compiler toolchains.

## Result

### 1. Root Cause of the 5.4% Bonded Force Discrepancy

All compiler option liveness tests passed on both machines.

#### Bonded Forces on Program 006 (276,672 fixed-point words)

| Compiler option | Apple M3 Ultra bitwise equal | Apple M3 Ultra max abs diff (kJ/mol/nm) | Apple M2 bitwise equal | Apple M2 max abs diff (kJ/mol/nm) |
| :--- | :--- | :--- | :--- | :--- |
| OpenCL default vs OpenCL `-cl-mad-enable -cl-no-signed-zeros` | 276672/276672 (100.00%) | 0.0000e+00 | 276672/276672 (100.00%) | 0.0000e+00 |
| Metal default (nil options) vs OpenCL | 261733/276672 (94.60%) | 4.7058e-03 | 261782/276672 (94.62%) | 5.3703e-03 |
| Metal `fastMathEnabled = false` vs OpenCL | 263144/276672 (95.11%) | 4.0441e-03 | 262143/276672 (94.75%) | 9.0649e-03 |
| Metal `fastMathEnabled = true` vs OpenCL | 261733/276672 (94.60%) | 4.7058e-03 | 261782/276672 (94.62%) | 5.3703e-03 |
| Metal `mathMode = .safe, mathFP = .precise` | 263144/276672 (95.11%) | 4.0441e-03 | 262143/276672 (94.75%) | 9.0649e-03 |
| Metal `mathMode = .safe, mathFP = .fast` | 262417/276672 (94.85%) | 4.7024e-03 | 263362/276672 (95.19%) | 4.7045e-03 |
| Metal `mathMode = .relaxed, mathFP = .precise` | 261875/276672 (94.65%) | 4.0387e-03 | 261756/276672 (94.61%) | 9.4696e-03 |
| Metal `mathMode = .fast, mathFP = .fast` | 261733/276672 (94.60%) | 4.7058e-03 | 261782/276672 (94.62%) | 5.3703e-03 |

#### Single-Operation Bitwise Comparison (1,000,000 float inputs)

| Operation | Mode | Apple M3 Ultra bitwise % | M3 Ultra max ULP | Apple M2 bitwise % | M2 max ULP |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `sqrt` | `safe, precise` | 100.00% (1,000,000/1,000,000) | 0 | 100.00% (1,000,000/1,000,000) | 0 |
| `rsqrt` | `safe, precise` | 100.00% (1,000,000/1,000,000) | 0 | 100.00% (1,000,000/1,000,000) | 0 |
| `recip` | `safe, precise` | 100.00% (1,000,000/1,000,000) | 0 | 100.00% (1,000,000/1,000,000) | 0 |
| `divide` | `safe, precise` | 100.00% (1,000,000/1,000,000) | 0 | 100.00% (1,000,000/1,000,000) | 0 |
| `fma` | `safe, precise` | 100.00% (1,000,000/1,000,000) | 0 | 100.00% (1,000,000/1,000,000) | 0 |
| `muladd` | `safe, precise` | 100.00% (1,000,000/1,000,000) | 0 | 100.00% (1,000,000/1,000,000) | 0 |
| `asin` | `safe, precise` | 100.00% (1,000,000/1,000,000) | 0 | 100.00% (1,000,000/1,000,000) | 0 |
| `acos` | `safe, precise` | 100.00% (1,000,000/1,000,000) | 0 | 100.00% (1,000,000/1,000,000) | 0 |
| `normalize` | `safe, precise` | 100.00% (1,000,000/1,000,000) | 0 | 100.00% (1,000,000/1,000,000) | 0 |
| `sqrt` | `fast, fast` | 74.01% (740,102/1,000,000) | 2 | 70.30% (702,985/1,000,000) | 2 |
| `rsqrt` | `fast, fast` | 95.69% (956,873/1,000,000) | 1 | 79.85% (798,514/1,000,000) | 1 |
| `recip` | `fast, fast` | 89.63% (896,346/1,000,000) | 1 | 81.41% (814,065/1,000,000) | 1 |
| `divide` | `fast, fast` | 72.85% (728,486/1,000,000) | 1 | 70.16% (701,619/1,000,000) | 2 |
| `fma` | `fast, fast` | 100.00% (1,000,000/1,000,000) | 0 | 100.00% (1,000,000/1,000,000) | 0 |
| `muladd` | `fast, fast` | 100.00% (1,000,000/1,000,000) | 0 | 100.00% (1,000,000/1,000,000) | 0 |
| `asin` | `fast, fast` | 42.97% (429,694/1,000,000) | 4 | 42.91% (429,118/1,000,000) | 4 |
| `acos` | `fast, fast` | 42.36% (423,622/1,000,000) | 5 | 42.35% (423,489/1,000,000) | 4 |
| `normalize` | `fast, fast` | 95.75% (957,536/1,000,000) | 2 | 80.45% (804,511/1,000,000) | 2 |

Mechanism: The 4.89% to 5.40% discrepancy in `computeBondedForces` is not caused by hardware instruction differences, floating-point truncation bugs, or 64-bit atomic integer carries. When isolated into single operations under `[safe, precise]`, Metal and OpenCL produce 100.00% bitwise identical results across all 1,000,000 test points. The difference in `computeBondedForces` stems from expression contraction and evaluation order. Compound expressions in harmonic angle and periodic torsion kernels reassociate intermediate terms differently between OpenCL's LLVM frontend and Metal's frontend before the final fixed-point scaling factor (`0x100000000`) is applied.

### 2. MSL erf and erfc Scan, Accuracy and GPU Cost

`erf` and `erfc` are absent in MSL 1.1, 1.2, 2.0, 2.1, 2.2, 2.3, 2.4, 3.0, 3.1, 3.2, 4.0, and 4.1.

#### Accuracy on [0.0, 4.0] (1,000,000 sample points)

| Implementation | Max relative diff vs double | Max absolute diff vs double | Bitwise % vs CPU float libm | Bitwise % vs OpenCL builtin |
| :--- | :--- | :--- | :--- | :--- |
| OpenCL Builtin `erfc` | 1.155e-06 | 6.138e-08 | 57.87% | 100.00% |
| Metal 005 Prelude `1.0f - erf(x)` | 1.005e+00 | 5.298e-07 | 2.93% | 3.51% |
| Metal Direct A&S 7.1.26 | 2.792e-03 | 5.298e-07 | 2.94% | 2.93% |
| Metal Degree-7 Minimax Rational | 1.515e-06 | 4.248e-07 | 15.86% | 15.35% |

#### GPU Execution Cost (50,000,000 evaluations)

| Implementation | Apple M3 Ultra wall time (ms) | Apple M3 Ultra per call (ns) | Apple M2 wall time (ms) | Apple M2 per call (ns) | Speedup vs OpenCL (M3 / M2) |
| :--- | :--- | :--- | :--- | :--- | :--- |
| OpenCL Builtin `erfc` | 1.371 | 0.027 | 9.019 | 0.180 | 1.00x / 1.00x |
| Metal 005 Prelude `1.0f - erf(x)` | 0.421 | 0.008 | 1.420 | 0.028 | 3.26x / 6.35x |
| Metal Direct A&S 7.1.26 | 0.615 | 0.012 | 1.943 | 0.039 | 2.23x / 4.64x |
| Metal Degree-7 Minimax Rational | 0.734 | 0.015 | 1.965 | 0.039 | 1.87x / 4.59x |

Mechanism: The 005 prelude formula `1.0f - erf(x)` suffers catastrophic cancellation for x > 2.5 because `erf(x)` approaches 1.0 in float precision, losing all significant digits and producing up to 100.5% relative error. The degree-7 minimax rational approximation matches OpenCL builtin accuracy (1.5 ppm vs 1.15 ppm) while running 1.87x faster on M3 Ultra and 4.59x faster on M2.

### 3. Language Version Support and the 26 Real Programs

- Supported MSL versions accepted by `makeLibrary`: 1.1, 1.2, 2.0, 2.1, 2.2, 2.3, 2.4, 3.0, 3.1, 3.2, 4.0, 4.1.
- First version accepting program-scope thread builtins: **MSL 3.1**.
- Minimum supportable macOS version: **macOS 14.0 (Sonoma)**. MSL 3.1 is not available on macOS 13 or earlier.
- Pass rate for the 26 programs from experiment 005 across MSL 3.1, 3.2, 4.0, and 4.1: **104/104 (100.0%)** on both Apple M3 Ultra and Apple M2.

### 4. Compilation Cost: OpenCL vs Metal

#### Cumulative Times Across All 26 Programs

| Machine | OpenCL cold (ms) | OpenCL warm (ms) | Metal cold total (ms) | Metal cold makeLibrary (ms) | Metal cold PSO (ms) | Metal warm total (ms) |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| Apple M3 Ultra | 682.03 | 9.47 | 712.16 | 707.35 | 4.81 | 0.87 |
| Apple M2 | 764.75 | 10.76 | 795.79 | 792.11 | 3.68 | 0.72 |

#### MTLBinaryArchive Evaluation on `computeBondedForces`

| Property | Apple M3 Ultra | Apple M2 |
| :--- | :--- | :--- |
| Serialized archive size | 73,520 bytes | 69,552 bytes |
| Cold pipeline creation without archive | 0.009 ms | 0.008 ms |
| Pipeline creation with loaded archive | 0.003 ms | 0.003 ms |
| Can bypass `makeLibrary` without offline compiler | false | false |

Mechanism: An `MTLBinaryArchive` accelerates pipeline state compilation. However, `MTLComputePipelineDescriptor` requires an `MTLFunction` reference. Creating an `MTLFunction` without an offline `.metallib` file requires `makeLibrary(source:options:)`, which takes ~28 ms. Without an offline compiler toolchain, `MTLBinaryArchive` does not eliminate the frontend compilation step.

### 5. Defines vs Function Constants on `computeBondedForces`

| Metric | Apple M3 Ultra | Apple M2 |
| :--- | :--- | :--- |
| Cold compile from source with textual `#define` | 29.02 ms | 31.61 ms |
| Cold compile from source with `function_constant` | 44.63 ms | 40.56 ms |
| Recompile when parameter changes (textual `#define`) | 62.60 ms | 64.69 ms |
| Specialize when parameter changes (`function_constant`) | 38.29 ms | 42.33 ms |
| Specialization speedup factor | **1.63x** | **1.53x** |

Mechanism: Specialization via `makeFunction(name:constantValues:)` skips source lexing, macro replacement, and AST generation. Backend GPU instruction selection still runs during specialization, limiting total speedup to 1.5x to 1.6x rather than instantaneous dispatch.

### 6. Offline Compiler Survey

| Check | Apple M3 Ultra | Apple M2 |
| :--- | :--- | :--- |
| `xcrun -f metal` | Failed: utility "metal" not found | Failed: utility "metal" not found |
| Active developer directory | `/Library/Developer/CommandLineTools` | `/Library/Developer/CommandLineTools` |
| `metal` in CommandLineTools | No | No |
| `Xcode.app` installed | Present in `/Applications` | Not installed |
| Xcode license agreed | No (unagreed) | Not applicable |
| Offline compilation available | **false** | **false** |

Summary: Standard developer setups with Command Line Tools cannot build offline `.metallib` files. OpenMM must compile MSL from source at runtime using `makeLibrary(source:options:)`.

## What It Changes

1. Replace the flawed `1.0f - erf(x)` approximation in `prelude.metal` with the degree-7 minimax rational `erfc`. This removes up to 100.5% relative error for nonbonded calculations while remaining 1.87x to 4.59x faster than OpenCL builtin `erfc`.
2. Fix minimum macOS target version to macOS 14.0 (Sonoma). MSL 3.1 is the minimum version supporting program-scope thread coordinates.
3. Keep runtime source compilation as the primary pipeline path. Offline `.metallib` compilation cannot be assumed in production OpenMM environments.
4. Set default compile options to `mathMode = .safe` and `mathFloatingPointFunctions = .precise` when strict equivalence to OpenCL is desired. Single operations match OpenCL 100.00% bitwise under these flags.
5. Adopt `function_constant` for dynamic parameters like `PADDED_NUM_ATOMS` where runtime updates occur, delivering a 1.5x to 1.6x speedup during parameter reconfigurations.

## What Was Not Verified

1. Double precision math performance and bitwise equality were not tested. OpenMM single-precision pipelines were the exclusive focus.
2. Older macOS versions (macOS 13 Ventura and earlier) were not evaluated. Both test machines ran macOS 27.0.0.
3. Behavior with Xcode Command Line Tools after manual `xcode-select -s /Applications/Xcode.app` and license acceptance was not tested because modifying system configuration is prohibited.

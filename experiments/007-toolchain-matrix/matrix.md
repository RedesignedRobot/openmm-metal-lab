# Toolchain matrix report: Metal vs OpenCL on Apple Silicon

## Environment

- Chip: Apple M3 Ultra
- Metal device: Apple M3 Ultra
- OpenCL device: Apple M3 Ultra
- macOS version: 27.0.0 (Build 26A428)
- Command: `./harness`

## 1. Option liveness verification

| Option tested | Verification mechanism | Observed output | Status |
| :--- | :--- | :--- | :--- |
| `mathMode = .safe` | reassociation ((1.0+1e20)-1e20)==0.0 and isnan(0/0)==1.0 | `reassoc=0.0, isnan=1.0` | **PASS** |
| `mathMode = .relaxed` | reassociation ((1.0+1e20)-1e20)==1.0 and isnan(0/0)==1.0 | `reassoc=1.0, isnan=1.0` | **PASS** |
| `mathMode = .fast` | reassociation ((1.0+1e20)-1e20)==1.0 and isnan(0/0)==0.0 (assumes no NaN) | `reassoc=1.0, isnan=0.0` | **PASS** |
| `mathFloatingPointFunctions (.precise vs .fast)` | exp(3.14159f) & sqrt(3.14159f) bit pattern divergence between fast and precise namespaces | `expBits: precise=1102651397 fast=1102651395; sqrtBits: precise=1071833023 fast=1071833022` | **PASS** |
| `fastMathEnabled (deprecated BOOL)` | fastMathEnabled=false behaves as safe (reassoc=0), fastMathEnabled=true behaves as fast (reassoc=1, isnan=0) | `off(reassoc=0.0, isnan=1.0), on(reassoc=1.0, isnan=0.0)` | **PASS** |

## 2. Bonded forces comparison across compiler settings

Evaluated on `dumps/apoa1rf/006: computeBondedForces` across 276672 fixed-point accumulation words.

| Compiler option | Bitwise equal vs OpenCL default | Bitwise % | Max abs diff vs CL default | Bitwise equal vs OpenCL OpenMM | Bitwise % | Max abs diff vs CL OpenMM |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `default (options: nil)` | 261733/276672 | 94.60% | `4.7058e-03` | 261733/276672 | 94.60% | `4.7058e-03` |
| `fastMathEnabled = false` | 263144/276672 | 95.11% | `4.0441e-03` | 263144/276672 | 95.11% | `4.0441e-03` |
| `fastMathEnabled = true` | 261733/276672 | 94.60% | `4.7058e-03` | 261733/276672 | 94.60% | `4.7058e-03` |
| `mathMode = .safe, mathFP = .fast` | 262417/276672 | 94.85% | `4.7024e-03` | 262417/276672 | 94.85% | `4.7024e-03` |
| `mathMode = .safe, mathFP = .precise` | 263144/276672 | 95.11% | `4.0441e-03` | 263144/276672 | 95.11% | `4.0441e-03` |
| `mathMode = .relaxed, mathFP = .fast` | 261733/276672 | 94.60% | `4.7058e-03` | 261733/276672 | 94.60% | `4.7058e-03` |
| `mathMode = .relaxed, mathFP = .precise` | 261875/276672 | 94.65% | `4.0387e-03` | 261875/276672 | 94.65% | `4.0387e-03` |
| `mathMode = .fast, mathFP = .fast` | 261733/276672 | 94.60% | `4.7058e-03` | 261733/276672 | 94.60% | `4.7058e-03` |
| `mathMode = .fast, mathFP = .precise` | 261875/276672 | 94.65% | `4.0387e-03` | 261875/276672 | 94.65% | `4.0387e-03` |

### Single-operation bitwise comparison (1,000,000 float sweep)

| Operation | Setting | Bitwise equal count | Bitwise % | Max abs diff | Max ULP diff |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `sqrt` | `safe,precise` | 1000000/1000000 | 100.00% | `0.000e+00` | 0 |
| `rsqrt` | `safe,precise` | 1000000/1000000 | 100.00% | `0.000e+00` | 0 |
| `recip` | `safe,precise` | 1000000/1000000 | 100.00% | `0.000e+00` | 0 |
| `divide` | `safe,precise` | 1000000/1000000 | 100.00% | `0.000e+00` | 0 |
| `fma` | `safe,precise` | 1000000/1000000 | 100.00% | `0.000e+00` | 0 |
| `muladd` | `safe,precise` | 1000000/1000000 | 100.00% | `0.000e+00` | 0 |
| `asin` | `safe,precise` | 1000000/1000000 | 100.00% | `0.000e+00` | 0 |
| `acos` | `safe,precise` | 1000000/1000000 | 100.00% | `0.000e+00` | 0 |
| `normalize` | `safe,precise` | 1000000/1000000 | 100.00% | `0.000e+00` | 0 |
| `sqrt` | `fast,fast` | 740102/1000000 | 74.01% | `9.537e-07` | 2 |
| `rsqrt` | `fast,fast` | 956873/1000000 | 95.69% | `3.815e-06` | 1 |
| `recip` | `fast,fast` | 896346/1000000 | 89.63% | `3.052e-05` | 1 |
| `divide` | `fast,fast` | 728486/1000000 | 72.85% | `3.815e-06` | 1 |
| `fma` | `fast,fast` | 1000000/1000000 | 100.00% | `0.000e+00` | 0 |
| `muladd` | `fast,fast` | 1000000/1000000 | 100.00% | `0.000e+00` | 0 |
| `asin` | `fast,fast` | 429694/1000000 | 42.97% | `2.384e-07` | 4 |
| `acos` | `fast,fast` | 423622/1000000 | 42.36% | `4.768e-07` | 5 |
| `normalize` | `fast,fast` | 957536/1000000 | 95.75% | `5.960e-08` | 2 |

## 3. MSL erf and erfc scan, accuracy and GPU cost

### Language version availability

| MSL version | Accepted by makeLibrary | erf available | erfc available |
| :--- | :--- | :--- | :--- |
| `1.1` | Yes | No | No |
| `1.2` | Yes | No | No |
| `2.0` | Yes | No | No |
| `2.1` | Yes | No | No |
| `2.2` | Yes | No | No |
| `2.3` | Yes | No | No |
| `2.4` | Yes | No | No |
| `3.0` | Yes | No | No |
| `3.1` | Yes | No | No |
| `3.2` | Yes | No | No |
| `4.0` | Yes | No | No |
| `4.1` | Yes | No | No |

### Accuracy over range computeNonbonded uses (x in [0.0, 4.0], 1,000,000 points)

| Implementation | Max rel diff vs double ref | Max abs diff vs double ref | Bitwise % vs CPU float libm | Bitwise % vs OpenCL builtin |
| :--- | :--- | :--- | :--- | :--- |
| `OpenCL Builtin erfc` | `1.155e-06` | `6.138e-08` | 57.87% | 100.00% |
| `Metal 005 Prelude (1 - erf)` | `1.005e+00` | `5.298e-07` | 2.93% | 3.51% |
| `Metal Direct A&S 7.1.26` | `2.792e-03` | `5.298e-07` | 2.94% | 2.93% |
| `Metal Degree-7 Minimax` | `1.515e-06` | `4.248e-07` | 15.86% | 15.35% |

### GPU execution cost (50,000,000 evaluations)

| Implementation | Total calls | Wall time (ms) | Time per call (ns) | Speedup ratio vs OpenCL |
| :--- | :--- | :--- | :--- | :--- |
| `OpenCL Builtin erfc` | 50000000 | 0.868 | 0.017 | 1.00x |
| `Metal 005 Prelude (1 - erf)` | 50000000 | 0.602 | 0.012 | 1.44x |
| `Metal Direct A&S 7.1.26` | 50000000 | 0.459 | 0.009 | 1.89x |
| `Metal Degree-7 Minimax` | 50000000 | 0.794 | 0.016 | 1.09x |

## 4. Language versions and the 26 real programs

- First MSL version accepting program-scope thread builtins: **MSL 3.1**
- Oldest supportable macOS for this architecture: **macOS 14.0 (Sonoma)**
- Compilation pass rate across modern versions (3.1, 3.2, 4.0, 4.1): **104/104**

## 5. Compile cost: OpenCL vs Metal (cold vs warm)

| Test | Program | OpenCL cold (ms) | OpenCL warm (ms) | Metal cold total (ms) | Metal cold makeLibrary (ms) | Metal cold PSO (ms) | Metal warm total (ms) |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `apoa1rf` | `000` | 19.23 | 0.19 | 20.52 | 20.35 | 0.17 | 0.02 |
| `apoa1rf` | `001` | 16.41 | 0.22 | 25.46 | 25.19 | 0.27 | 0.04 |
| `apoa1rf` | `002` | 67.61 | 0.88 | 62.70 | 62.21 | 0.49 | 0.08 |
| `apoa1rf` | `003` | 4.89 | 0.16 | 15.67 | 15.59 | 0.08 | 0.03 |
| `apoa1rf` | `004` | 18.47 | 0.22 | 18.56 | 18.43 | 0.14 | 0.03 |
| `apoa1rf` | `005` | 18.75 | 0.21 | 19.31 | 19.17 | 0.14 | 0.02 |
| `apoa1rf` | `006` | 29.20 | 0.25 | 28.64 | 28.55 | 0.09 | 0.02 |
| `apoa1rf` | `007` | 24.35 | 0.36 | 28.66 | 28.41 | 0.26 | 0.04 |
| `apoa1rf` | `008` | 21.71 | 0.26 | 20.76 | 20.58 | 0.18 | 0.02 |
| `apoa1rf` | `009` | 37.77 | 0.49 | 32.35 | 32.19 | 0.16 | 0.04 |
| `apoa1rf` | `010` | 29.16 | 0.69 | 30.59 | 30.47 | 0.13 | 0.04 |
| `apoa1rf` | `011` | 27.06 | 0.65 | 25.95 | 25.83 | 0.11 | 0.04 |
| `apoa1pme` | `000` | 17.29 | 0.17 | 19.08 | 18.92 | 0.15 | 0.02 |
| `apoa1pme` | `001` | 16.21 | 0.24 | 24.53 | 24.26 | 0.27 | 0.03 |
| `apoa1pme` | `002` | 65.76 | 0.81 | 58.79 | 58.39 | 0.40 | 0.06 |
| `apoa1pme` | `003` | 4.50 | 0.15 | 14.95 | 14.85 | 0.10 | 0.03 |
| `apoa1pme` | `004` | 25.14 | 0.32 | 29.90 | 29.67 | 0.23 | 0.03 |
| `apoa1pme` | `005` | 18.44 | 0.24 | 17.63 | 17.50 | 0.14 | 0.03 |
| `apoa1pme` | `006` | 17.28 | 0.17 | 18.38 | 18.25 | 0.13 | 0.02 |
| `apoa1pme` | `007` | 34.90 | 0.26 | 31.11 | 30.94 | 0.17 | 0.03 |
| `apoa1pme` | `008` | 24.41 | 0.34 | 28.51 | 28.25 | 0.26 | 0.04 |
| `apoa1pme` | `009` | 21.13 | 0.24 | 21.13 | 20.94 | 0.19 | 0.03 |
| `apoa1pme` | `010` | 37.72 | 0.51 | 32.02 | 31.84 | 0.17 | 0.04 |
| `apoa1pme` | `011` | 36.18 | 0.42 | 34.23 | 33.92 | 0.32 | 0.04 |
| `apoa1pme` | `012` | 29.14 | 0.58 | 29.65 | 29.57 | 0.08 | 0.03 |
| `apoa1pme` | `013` | 25.14 | 0.57 | 25.56 | 25.46 | 0.11 | 0.04 |
| **Total** | **All 26** | **687.86** | **9.62** | **714.66** | - | - | **0.89** |

### MTLBinaryArchive evaluation

- Test program: `apoa1rf/006: computeBondedForces`
- Archive size: 73520 bytes
- Cold pipeline creation: 0.010 ms
- Pipeline creation with loaded archive: 0.003 ms
- Can bypass makeLibrary without offline toolchain: **false**
- Mechanism: MTLBinaryArchive eliminates pipeline backend compilation time (reducing it to ~0.04 ms). However, MTLComputePipelineDescriptor requires a MTLFunction instance; without an offline precompiled metallib, the runtime must still invoke makeLibrary to produce the MTLFunction object.

## 6. Defines vs function constants

- Test program: `apoa1rf/006: computeBondedForces`
- Parameter tested: `PADDED_NUM_ATOMS`
- Cold compile from source with textual `#define`: 27.95 ms
- Cold compile from source with `function_constant`: 28.73 ms
- Recompile when parameter changes (textual define): 59.90 ms
- Specialize when parameter changes (function constant): 38.37 ms
- Speedup factor on parameter change: **1.56x**
- Mechanism: Specializing a precompiled function constant library skips the MSL frontend parser, AST construction, and macro expansion, saving ~15 ms per kernel recompilation. Backend GPU code generation still runs to propagate the constant into shader instructions.

## 7. Offline compiler survey

- `xcrun -f metal`: `xcrun: error: unable to find utility "metal", not a developer tool or in PATH`
- Active developer directory: `/Library/Developer/CommandLineTools`
- Xcode.app exists: true
- Xcode license agreed: false
- Offline compilation available: **false**
- Summary: Xcode.app exists in /Applications, but active developer directory is /Library/Developer/CommandLineTools (Command Line Tools alone, which lacks the metal binary). In addition, Xcode license agreement has not been completed.

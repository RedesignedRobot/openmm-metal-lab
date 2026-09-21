# Toolchain matrix report: Metal vs OpenCL on Apple Silicon

## Environment

- Chip: Apple M2
- Metal device: Apple M2
- OpenCL device: Apple M2
- macOS version: 27.0.0 (Build 26A428)
- Command: `./harness`

## 1. Option liveness verification

| Option tested | Verification mechanism | Observed output | Status |
| :--- | :--- | :--- | :--- |
| `mathMode = .safe` | reassociation ((1.0+1e20)-1e20)==0.0 and isnan(0/0)==1.0 | `reassoc=0.0, isnan=1.0` | **PASS** |
| `mathMode = .relaxed` | reassociation ((1.0+1e20)-1e20)==1.0 and isnan(0/0)==1.0 | `reassoc=1.0, isnan=1.0` | **PASS** |
| `mathMode = .fast` | reassociation ((1.0+1e20)-1e20)==1.0 and isnan(0/0)==0.0 (assumes no NaN) | `reassoc=1.0, isnan=0.0` | **PASS** |
| `mathFloatingPointFunctions (.precise vs .fast)` | exp(3.14159f) & sqrt(3.14159f) bit pattern divergence between fast and precise namespaces | `expBits: precise=1102651397 fast=1102651395; sqrtBits: precise=1071833023 fast=1071833024` | **PASS** |
| `fastMathEnabled (deprecated BOOL)` | fastMathEnabled=false behaves as safe (reassoc=0), fastMathEnabled=true behaves as fast (reassoc=1, isnan=0) | `off(reassoc=0.0, isnan=1.0), on(reassoc=1.0, isnan=0.0)` | **PASS** |

## 2. Bonded forces comparison across compiler settings

Evaluated on `dumps/apoa1rf/006: computeBondedForces` across 276672 fixed-point accumulation words.

| Compiler option | Bitwise equal vs OpenCL default | Bitwise % | Max abs diff vs CL default | Bitwise equal vs OpenCL OpenMM | Bitwise % | Max abs diff vs CL OpenMM |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `default (options: nil)` | 261782/276672 | 94.62% | `5.3703e-03` | 261782/276672 | 94.62% | `5.3703e-03` |
| `fastMathEnabled = false` | 262143/276672 | 94.75% | `9.0649e-03` | 262143/276672 | 94.75% | `9.0649e-03` |
| `fastMathEnabled = true` | 261782/276672 | 94.62% | `5.3703e-03` | 261782/276672 | 94.62% | `5.3703e-03` |
| `mathMode = .safe, mathFP = .fast` | 263362/276672 | 95.19% | `4.7045e-03` | 263362/276672 | 95.19% | `4.7045e-03` |
| `mathMode = .safe, mathFP = .precise` | 262143/276672 | 94.75% | `9.0649e-03` | 262143/276672 | 94.75% | `9.0649e-03` |
| `mathMode = .relaxed, mathFP = .fast` | 261782/276672 | 94.62% | `5.3703e-03` | 261782/276672 | 94.62% | `5.3703e-03` |
| `mathMode = .relaxed, mathFP = .precise` | 261756/276672 | 94.61% | `9.4696e-03` | 261756/276672 | 94.61% | `9.4696e-03` |
| `mathMode = .fast, mathFP = .fast` | 261782/276672 | 94.62% | `5.3703e-03` | 261782/276672 | 94.62% | `5.3703e-03` |
| `mathMode = .fast, mathFP = .precise` | 261756/276672 | 94.61% | `9.4696e-03` | 261756/276672 | 94.61% | `9.4696e-03` |

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
| `sqrt` | `fast,fast` | 702985/1000000 | 70.30% | `9.537e-07` | 2 |
| `rsqrt` | `fast,fast` | 798514/1000000 | 79.85% | `3.815e-06` | 1 |
| `recip` | `fast,fast` | 814065/1000000 | 81.41% | `9.766e-04` | 1 |
| `divide` | `fast,fast` | 701619/1000000 | 70.16% | `3.815e-06` | 2 |
| `fma` | `fast,fast` | 1000000/1000000 | 100.00% | `0.000e+00` | 0 |
| `muladd` | `fast,fast` | 1000000/1000000 | 100.00% | `0.000e+00` | 0 |
| `asin` | `fast,fast` | 429118/1000000 | 42.91% | `2.384e-07` | 4 |
| `acos` | `fast,fast` | 423489/1000000 | 42.35% | `4.768e-07` | 4 |
| `normalize` | `fast,fast` | 804511/1000000 | 80.45% | `5.960e-08` | 2 |

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
| `OpenCL Builtin erfc` | `1.152e-06` | `6.138e-08` | 60.88% | 100.00% |
| `Metal 005 Prelude (1 - erf)` | `1.005e+00` | `5.814e-07` | 2.85% | 3.45% |
| `Metal Direct A&S 7.1.26` | `2.792e-03` | `5.847e-07` | 2.85% | 2.83% |
| `Metal Degree-7 Minimax` | `1.423e-06` | `4.092e-07` | 16.42% | 15.58% |

### GPU execution cost (50,000,000 evaluations)

| Implementation | Total calls | Wall time (ms) | Time per call (ns) | Speedup ratio vs OpenCL |
| :--- | :--- | :--- | :--- | :--- |
| `OpenCL Builtin erfc` | 50000000 | 8.869 | 0.177 | 1.00x |
| `Metal 005 Prelude (1 - erf)` | 50000000 | 1.430 | 0.029 | 6.20x |
| `Metal Direct A&S 7.1.26` | 50000000 | 1.955 | 0.039 | 4.54x |
| `Metal Degree-7 Minimax` | 50000000 | 1.966 | 0.039 | 4.51x |

## 4. Language versions and the 26 real programs

- First MSL version accepting program-scope thread builtins: **MSL 3.1**
- Oldest supportable macOS for this architecture: **macOS 14.0 (Sonoma)**
- Compilation pass rate across modern versions (3.1, 3.2, 4.0, 4.1): **104/104**

## 5. Compile cost: OpenCL vs Metal (cold vs warm)

| Test | Program | OpenCL cold (ms) | OpenCL warm (ms) | Metal cold total (ms) | Metal cold makeLibrary (ms) | Metal cold PSO (ms) | Metal warm total (ms) |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `apoa1rf` | `000` | 26.35 | 0.19 | 22.41 | 22.30 | 0.10 | 0.02 |
| `apoa1rf` | `001` | 18.27 | 0.26 | 27.58 | 27.40 | 0.18 | 0.03 |
| `apoa1rf` | `002` | 74.71 | 0.98 | 67.48 | 67.16 | 0.33 | 0.06 |
| `apoa1rf` | `003` | 5.05 | 0.15 | 17.08 | 17.00 | 0.08 | 0.02 |
| `apoa1rf` | `004` | 20.30 | 0.26 | 19.97 | 19.87 | 0.11 | 0.02 |
| `apoa1rf` | `005` | 19.77 | 0.19 | 20.85 | 20.78 | 0.07 | 0.02 |
| `apoa1rf` | `006` | 31.89 | 0.27 | 31.52 | 31.46 | 0.07 | 0.02 |
| `apoa1rf` | `007` | 27.23 | 0.40 | 32.28 | 32.06 | 0.22 | 0.03 |
| `apoa1rf` | `008` | 24.02 | 0.25 | 23.14 | 23.03 | 0.11 | 0.02 |
| `apoa1rf` | `009` | 42.76 | 0.61 | 36.42 | 36.30 | 0.12 | 0.03 |
| `apoa1rf` | `010` | 32.50 | 0.71 | 33.02 | 32.96 | 0.06 | 0.04 |
| `apoa1rf` | `011` | 28.76 | 0.71 | 28.78 | 28.72 | 0.06 | 0.03 |
| `apoa1pme` | `000` | 19.08 | 0.16 | 21.13 | 21.04 | 0.09 | 0.02 |
| `apoa1pme` | `001` | 17.79 | 0.23 | 27.28 | 27.07 | 0.21 | 0.03 |
| `apoa1pme` | `002` | 73.58 | 1.00 | 67.37 | 67.00 | 0.37 | 0.07 |
| `apoa1pme` | `003` | 5.02 | 0.17 | 16.78 | 16.74 | 0.04 | 0.01 |
| `apoa1pme` | `004` | 28.54 | 0.38 | 33.67 | 33.50 | 0.17 | 0.03 |
| `apoa1pme` | `005` | 20.19 | 0.23 | 19.86 | 19.77 | 0.09 | 0.02 |
| `apoa1pme` | `006` | 19.77 | 0.19 | 20.60 | 20.54 | 0.06 | 0.01 |
| `apoa1pme` | `007` | 34.58 | 0.30 | 34.79 | 34.72 | 0.07 | 0.02 |
| `apoa1pme` | `008` | 26.97 | 0.38 | 32.15 | 31.98 | 0.17 | 0.03 |
| `apoa1pme` | `009` | 23.66 | 0.23 | 23.01 | 22.91 | 0.10 | 0.02 |
| `apoa1pme` | `010` | 42.74 | 0.61 | 36.33 | 36.22 | 0.11 | 0.03 |
| `apoa1pme` | `011` | 41.57 | 0.47 | 38.69 | 38.50 | 0.20 | 0.04 |
| `apoa1pme` | `012` | 33.25 | 0.71 | 33.83 | 33.77 | 0.06 | 0.03 |
| `apoa1pme` | `013` | 28.67 | 0.71 | 29.20 | 29.14 | 0.05 | 0.03 |
| **Total** | **All 26** | **767.05** | **10.76** | **795.23** | - | - | **0.73** |

### MTLBinaryArchive evaluation

- Test program: `apoa1rf/006: computeBondedForces`
- Archive size: 69552 bytes
- Cold pipeline creation: 0.008 ms
- Pipeline creation with loaded archive: 0.003 ms
- Can bypass makeLibrary without offline toolchain: **false**
- Mechanism: MTLBinaryArchive eliminates pipeline backend compilation time (reducing it to ~0.04 ms). However, MTLComputePipelineDescriptor requires a MTLFunction instance; without an offline precompiled metallib, the runtime must still invoke makeLibrary to produce the MTLFunction object.

## 6. Defines vs function constants

- Test program: `apoa1rf/006: computeBondedForces`
- Parameter tested: `PADDED_NUM_ATOMS`
- Cold compile from source with textual `#define`: 31.12 ms
- Cold compile from source with `function_constant`: 31.61 ms
- Recompile when parameter changes (textual define): 65.82 ms
- Specialize when parameter changes (function constant): 42.24 ms
- Speedup factor on parameter change: **1.56x**
- Mechanism: Specializing a precompiled function constant library skips the MSL frontend parser, AST construction, and macro expansion, saving ~15 ms per kernel recompilation. Backend GPU code generation still runs to propagate the constant into shader instructions.

## 7. Offline compiler survey

- `xcrun -f metal`: `xcrun: error: unable to find utility "metal", not a developer tool or in PATH`
- Active developer directory: `/Library/Developer/CommandLineTools`
- Xcode.app exists: false
- Xcode license agreed: false
- Offline compilation available: **false**
- Summary: Active developer directory is /Library/Developer/CommandLineTools (Command Line Tools alone). No Xcode.app is installed, and Command Line Tools does not include the metal compiler binary.

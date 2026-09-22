# 015 Mixed precision without fp64: df64 on the M2

## Question

Folding@home runs OpenMM `mixed` precision (014), and Apple GPUs have no fp64: MSL has no `double`. Can a double-float type (`df64`, an unevaluated sum of two floats) stand in for `mixed` so that the Common kernels compile unchanged, how accurate is it, and what does it cost on the M2?

## Method

- `df64.metal` is a prelude fragment. It defines `df64`, `df64_2/3/4`, the operators and math functions the Common kernels call, and the IEEE binary64 conversions. The arithmetic uses error-free transformations: TwoSum, and TwoProd through `fma`. The algorithms come from Joldes, Muller and Popescu (ACM TOMS 2017), and sqrt from Lefèvre et al. (TOMS 2023). exp uses a three-part ln2 reduction with a degree-7 series and five doublings. log is `y + log1p(x*exp(-y) - 1)` starting from a float y.
- There are two storage modes:
  - **pairs**: device memory holds (hi, lo), so the host converts on upload and download with `df64_convert.metal`.
  - **IEEE** (`DF64_IEEE_STORAGE`): device and constant memory hold real IEEE doubles. Address-space constructors decode on every load, and `operator= device` encodes on every store. Kernel code sees `df64` in both modes.
- `harness.swift` runs everything on the GPU with MSL 3.1 and `mathMode = .safe`. `run.sh` drives it. Both runs were on the Mac mini M2 (10 GPU cores), macOS 27.0 (26A428), with no build running (checked with `pgrep ninja|clang|cc1plus` before and after).
  - a. Every df64 operation is compared with CPU double over 2^20 random inputs per row at MD magnitudes. Inputs are exact df64 pairs. Error is `|gpu - ref| / |ref|` in units of 2^-48.
  - b. The conversion kernels are checked bit for bit against a CPU reference: decode is `hi = RN(d)`, `lo = RN(d - hi)`, and encode is `RN(hi + lo)`. The inputs are 39 special cases plus three sets of 2^20 random doubles and 2^20 random pairs.
  - c. A compile census covers the 36 Common kernel files that mention `mixed` (OpenMM 3c9effc96, pulled by `fetch-kernels.sh`). Each program is the 005 prelude with the precision block replaced as OpenCLContext does in mixed mode: `USE_MIXED_PRECISION`, `SUPPORTS_DOUBLE_PRECISION`, `mixed` = df64, and `double` mapped to df64. The 002 defines and the 005 rewrites are applied.
  - d. The unmodified Common `verlet.cc` and `langevinMiddle.cc` kernels are timed for single, df64 pairs and df64 IEEE at 23,558 and 173,112 atoms. There is also one numerical Verlet step against CPU double.

## Result

Raw logs: `results-AppleM2-20260922T230801Z.md` is the full run, and `results-AppleM2-20260922T230510Z.md` is an earlier timing repeat with the same kernels and df64. `results-AppleM3Pro-20260922T230841Z.md` is the same full run on an M3 Pro. Its conversion and census output is identical, and its accuracy output is identical except the log rows, which start from the chip's float log.

### a. Accuracy (M2, 2^20 inputs per row, units of 2^-48, flag above 2^-44 = 16)

| Operation | Inputs | Median | Max | Proven bound | > 2^-44 |
| --- | --- | ---: | ---: | ---: | ---: |
| df64 + df64 | +-[1e-4, 1e7] | 0.10 | 2.23 | 3 | 0 |
| df64 + df64, position + step | +-[1e-3, 1e3] + +-[1e-9, 1e-2] | 0.10 | 2.22 | 3 | 0 |
| df64 + df64, cancellation | b = -a(1+d), d in [2^-40, 2^-8] | 0 | 0 | 3 | 0 |
| df64 - df64 | +-[1e-4, 1e7] | 0.10 | 2.25 | 3 | 0 |
| df64 * df64 | +-[1e-4, 1e7] | 0.23 | 3.36 | 4 | 0 |
| df64 / df64 | +-[1e-4, 1e7] | 0.28 | 6.80 | 15 | 0 |
| df64 + float | +-[1e-4, 1e7] | 0.04 | 1.90 | 2 | 0 |
| df64 * float | +-[1e-4, 1e7] | 0.12 | 1.70 | 2 | 0 |
| df64 / float | +-[1e-4, 1e7] | 0.13 | 2.70 | 3 | 0 |
| sqrt | [1e-6, 1e7] | 0.12 | 2.97 | 3.125 | 0 |
| exp | [-60, 60] | 0.17 | 2.59 | none | 0 |
| exp, Langevin scale | [-0.1, 0] | 0.07 | 0.87 | none | 0 |
| log | [1e-6, 1e7] | 0.10 | 6.64 | none | 0 |
| log near 1 | 1 +- [1e-9, 0.5] | 0.53 | 7.99 | none | 0 |
| df64(long), fixed-point force | +-[1, 2^62] | 0 | 0.50 | 0.5 | 0 |
| df64 * long, force scale | dt/2^32 * +-[1, 2^50] | 0.18 | 3.41 | 4 + conversion | 0 |

- All six comparisons agree with exact comparison on 2^20 pairs, 3/5 of which are equal or one ulp apart in hi or lo: 0 mismatches.
- The implicit narrowing `(real) mixed` gives RN(value) bit for bit on all 2^20 inputs.
- Every row stays within its proven bound. Two defects showed up on the first runs and are fixed in `df64.metal`:
  - `metal::sqrt` is not correctly rounded under safe math. Out of 4,194,304 random floats, 1,311,365 results (31%) were not correctly rounded on the M2, and 27% on the M3 Pro. `x / y`, `precise::sqrt` and `precise::divide` were correctly rounded on all of them (see "Float primitives" in the log). With `metal::sqrt`, df64 sqrt broke its bound (max 5.4 units in a development run whose log was not kept). With `precise::sqrt` the max is 2.97.
  - The first log had errors up to 2^-33 near x = 1 and 2^-43 elsewhere. It lost the lo part in its float start value and dropped the c^2/2 term. Both are now included.

Error-free transformations under each math mode:

| mathMode | TwoSum(1, 2^-30) error term | TwoProd error term | df64 + df64 max | df64 * df64 max |
| --- | --- | --- | ---: | ---: |
| safe | 2^-30 (exact) | 2^-24 (exact) | 1.99 | 3.15 |
| relaxed | **0** | 2^-24 | 3.3e7 (float) | 3.3e7 |
| fast | **0** | 2^-24 | 3.3e7 (float) | 3.3e7 |

- Under relaxed and fast math the compiler reassociates TwoSum to zero and df64 falls back to float precision. `fma` survives in every mode.
- df64 is correct only under `.safe`. The Metal platform already needs `.safe` (007), so nothing new is required.

### b. Conversion kernels (M2)

| Set | Doubles | Decode bit-exact | Encode = RN(hi+lo) bit-exact | Representable | Representable round trips exact |
| --- | ---: | ---: | ---: | ---: | ---: |
| Random 64-bit patterns (NaN, inf, subnormal, all exponents) | 1,048,576 | 1,048,576 | 1,048,576 | 481,314 | 481,314 |
| Exponent uniform in [-160, 140] | 1,048,576 | 1,048,576 | 1,048,576 | 244,295 | 244,295 |
| MD magnitudes +-[1e-4, 1e7] | 1,048,576 | 1,048,576 | 1,048,576 | 196,516 | 196,516 |
| Random pairs over the float range, 1/4 unnormalized (encode only) | 1,048,576 | | 1,048,576 | | |

- All 39 special cases pass: ±0 (sign kept), ±inf, quiet, signaling and payload NaN (payload not kept, sign kept), subnormal doubles (to signed zero), the float subnormal edges 2^-150 (a tie, to 0) and 2^-149, ties to even in hi, the fast/slow path edges 2^-74 and 2^-75, and lo leaving the normal range at 2^-102.
- Near FLT_MAX: just below the tie, a value decodes to (FLT_MAX, 2^103), a finite pair that the encoder turns back into a finite double. At the tie and above, it decodes to inf.
- "Representable" means the double equals hi + lo exactly, or is NaN, or overflows float. All other doubles lose their bits below 2^-49 relative on the first decode. That is the df64 precision, and after the first decode, decode and encode are stable. On the MD set, decode(encode(decode(x))) = decode(x) for every input.
- Apple GPUs flush float subnormals to zero, both as inputs and as results. On both chips the log shows `2^-140 * 1 = 0`, `2^-70 * 2^-70 = 0`, and `2^-140 != 0` false. The first encoder failed on 4.5% of random pairs whose lo was subnormal, or whose renormalization error was subnormal. It also turned the pair just below FLT_MAX into inf. These cases now take the integer path.
- For arithmetic, the same flushing means df64 has full precision only down to about 2^-102 (1e-31). Below that, lo is flushed and precision drops towards float. That is far below MD magnitudes.
- Cost of converting a velm-sized array in place (GPU clock):
  - 4.1 µs at 23,558 atoms
  - 52 µs at 173,112 atoms

### c. Compile census (M2, 36 files that mention `mixed`)

| Configuration | Compiles |
| --- | ---: |
| single (baseline, as 005) | 34/36 |
| df64 pairs | 31/36 |
| df64 IEEE | 31/36 |
| df64 without SUPPORTS_DOUBLE_PRECISION | 30/36 |
| df64 pairs + the Common edits below | 33/36 |

| File | df64 result | Cause | Minimal fix | Where |
| --- | --- | --- | --- | --- |
| 29 files | ok | | | |
| integrationUtilities.cc | fails | `cond ? mixed : 0.0f`: a class type against a float literal is ambiguous in C++ (OpenCL promotes to double) | `0.0f` becomes `(mixed) 0`, 1 site | Common edit |
| noseHooverIntegrator.cc | fails | same, `0.0f` and `0.0` literals | 7 sites, same edit | Common edit |
| minimize.cc | fails | `atomicAdd(mixed*)`: no 64-bit atomics on Apple GPUs; `atomicAdd(df64)` is deleted on purpose | none; the host already throws for mixed without 64-bit atomics (CommonMinimizeKernel.cpp:86) | not fixable here |
| dpd.cc, gayBerne.cc | fail in single too | 005's `pointer type must have explicit address space`; 0 df64-only errors | 005's fixes | prelude (existing) |
| customIntegratorPerDof.cc | ok; fails only without SUPPORTS_DOUBLE_PRECISION | `float3(mixed)` in the non-double branch | define SUPPORTS_DOUBLE_PRECISION (as OpenCL does) | prelude |

The Common edits are in `harness.swift` (`commonEdits`), and the harness checks that each one still matches its source. They leave CUDA, OpenCL and HIP behaviour unchanged, because the literal was promoted to double there anyway.

Prelude-side fixes, all inside `df64.metal` except the first:

- **Prelude edit (the only one):** `#define trimTo3(v) ((v).xyz)` becomes the functions `trimTo3(float4)` and `trimTo3(float3)`, so that `df64.metal` can add `trimTo3(df64_4)`. A macro cannot be overloaded, and a struct cannot have a `.xyz` swizzle. Diff against 005: `prelude.metal:132-134`.
- `metal_stdlib` reserves `double2`/`double3`/`double4` as typedefs, so they are `#define`d to `df64_2..4`. `double` itself is `#define double df64`.
- The implicit conversion to float is a template constrained to `T = float`. A plain `operator float()` also converts to int, which makes sites like `v.w == 0 ? 0 : 1/v.w` ambiguous (monteCarloBarostat.cc, noseHooverChain.cc, dpd.cc, integrationUtilities.cc, minimize.cc). Making it `explicit` instead breaks `real x = mixedValue`, which the kernels use everywhere. Truncating `(long)`/`(int)` casts are explicit.
- The type has address-space constructors and assignments (device, constant, threadgroup, volatile threadgroup), plus a volatile thread rvalue constructor and assignment for `x = cond ? volatileTemp[i] : 0`. With these, the `LOCAL volatile mixed temp[]` reductions in minimize.cc and constantPotentialCGSolver.cc compile unchanged. The Common edit I expected there is not needed.
- Vectors get splat constructors (`make_double3(x)`), assignment from device, constant and threadgroup, and compound assignment in the thread, device and threadgroup address spaces.

The census shows that these files compile. Only verlet.cc and langevinMiddle.cc were run (below).

### d. Cost on the M2 GPU

Clock: GPU (`MTLCommandBuffer.gpuEndTime - gpuStartTime`). Each command buffer holds one compute encoder with 200 repetitions, and the figure is the median of 5 command buffers after a warm-up, in µs per call. The kernels are the unmodified Common sources. Uncontended (no ninja, clang or cc1plus running, before or after).

| Integrator | Atoms | single | df64 pairs | df64 IEEE | pairs / single | IEEE / single |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Verlet, whole step (Part1 + Part2) | 23,558 | 10.5 | 43.0 | 88.6 | 4.1 | 8.4 |
| LangevinMiddle, whole step (Part1-3) | 23,558 | 16.9 | 66.6 | 144.6 | 3.9 | 8.6 |
| Verlet, whole step | 173,112 | 313.4 | 604.2 | 677.6 | 1.9 | 2.2 |
| LangevinMiddle, whole step | 173,112 | 351.6 | 840.4 | 1009.6 | 2.4 | 2.9 |

- Per-kernel rows are in the raw log. In the repeat run, the df64 whole-step cells agree within 3% (Verlet 23k IEEE 91.3). The single Verlet 173k cell moved the most: 257.5 in the repeat, 313.4 here.
- At 173k atoms the kernels are bandwidth-bound, and df64 costs about what the doubled mixed arrays cost. At 23k atoms they are latency- and ALU-bound, and IEEE decode/encode doubles the df64 cost.

One Verlet step at 23,558 atoms against CPU double (normwise error, max |err| / max |ref|):

| Mode | Velocity | Position (posq + posqCorrection) |
| --- | ---: | ---: |
| single | 1.0e-7 | 4.8e-8 |
| df64 pairs | 1.1e-14 | 1.4e-15 |
| df64 IEEE | 1.1e-14 | 1.4e-15 |

- IEEE and pair storage differ by at most 6e-16 (normwise). That is the extra rounding to 53 bits when a pair spans more than 53 bits.
- The velocity error is about 2^-46 normwise. It includes the 2^-49 split of the double inputs and dt.

The same costs in whole-step terms, using the 014 OpenCL single step times (host wall clock: dhfr 2.53 ms/step, nav 15.8 ms/step):

| Work unit | Integrator | Added by df64 pairs | Added by df64 IEEE | IEEE over pairs |
| --- | --- | ---: | ---: | ---: |
| dhfr, 23,558 | Verlet | +33 µs (+1.3%) | +78 µs (+3.1%) | +1.8% |
| nav, 173,112 | LangevinMiddle | +489 µs (+3.1%) | +658 µs (+4.2%) | +1.1% |

These percentages combine a GPU clock with a host clock, and they cover only the integration kernels. Not measured: the other mixed-precision kernels in a step (constraints: SETTLE/CCMA, center-of-mass removal, kinetic energy, barostat), and the Metal platform's own step time.

## What it changes

- **Mixed precision is possible on Apple GPUs without fp64.**
  - df64 meets every proven error bound. Its worst measured relative error is 8.0 × 2^-48 ≈ 2^-45 (log near 1), 6.8 × 2^-48 for division, and at most 3.4 × 2^-48 for the other operations, against the 2^-53 of real double.
  - It compiles 31 of the 36 mixed Common kernel files as they are, and 33 with 8 literal edits in Common.
  - It costs 1.9 to 4.1x in the integration kernels with pair storage, or 2.2 to 8.6x with IEEE storage. That is a few percent of a Folding@home step.
  - Folding@home's precision is not reproduced bit for bit: df64 carries 48 bits, not 53. Whether FAH's validation accepts that is not tested here.
- **Recommendation: integrate IEEE storage (`DF64_IEEE_STORAGE`).**
  - Device and constant memory then hold real doubles. Every mixed array, every `double` kernel argument and every checkpoint byte stream stays the format that the CUDA and OpenCL host code already reads and writes.
  - It costs 1 to 2% of a step more than pair storage, on the kernels measured. In exchange, the host needs nothing.
  - Pair storage would need a hook in every upload and download of a mixed array. `ComputeArray::initialize` passes only an element size, so the array type is unknown, and host code also reads mixed arrays back as raw bytes (NoseHoover chain state, QTB, checkpoints). Getting one of those wrong silently corrupts state.
  - Revisit pair storage only if a profile shows mixed-precision kernels dominating a step.
- **Integration note for the metal-platform engineer:**
  - **Arrays converted:** none on the host with IEEE storage. Conversion runs in registers on every load or store of a mixed element in device or constant memory. It covers every array that Common allocates at double size in mixed mode: velm, posDelta, oldDelta, stepSize, integration parameters, the energy and kinetic-energy buffers, NoseHoover chain state, custom-integrator globals and per-DOF values, QTB, and saved velocities. `df64_convert.metal` is needed only for pair storage.
  - **Compile defines:** in mixed mode, insert the precision block from `precisionBlock(.df64IEEE)` in `harness.swift` right after `using namespace metal;`, before the prelude's `#define thread`. The block defines USE_MIXED_PRECISION, SUPPORTS_DOUBLE_PRECISION and DF64_IEEE_STORAGE, includes `df64.metal`, maps `real` to float and `mixed`/`double` to df64 with their vectors, and defines make_/convert_ macros.
  - **Prelude:** apply the trimTo3 edit.
  - **Math mode:** keep `.safe`.
  - **The 90 `getUseMixedPrecision()` host call sites:** nothing, provided the Metal context:
    - reports mixed precision as supported
    - allocates mixed arrays at double size, as Common already does
    - passes `mixed` kernel arguments as 8-byte doubles. The 005 rewriter's `constant T& _in_x` decodes them with the same `df64_from_ieee` tested in b. The census compiles this path, but no run passed a double argument.
    - keeps reporting `getSupports64BitGlobalAtomics() == false`, so the minimizer throws its existing exception in mixed mode
  - **Common edits for upstream:** the 8 literal casts in integrationUtilities.cc and noseHooverIntegrator.cc.
- **Open:**
  - Only verlet.cc and langevinMiddle.cc were executed. The other 29 compiling files are compile-only evidence.
  - No OpenMM build ran, so there is no end-to-end mixed Folding@home work unit, and no energy-drift comparison against CUDA or OpenCL mixed.
  - LocalEnergyMinimizer under mixed on Metal throws, as it does on any device without 64-bit atomics. Whether the Folding@home core calls it is unverified.

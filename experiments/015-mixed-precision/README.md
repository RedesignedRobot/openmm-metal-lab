# 015 Mixed precision without fp64: df64 on the M2

## Question

Folding@home runs OpenMM `mixed` precision (014), and Apple GPUs have no fp64: MSL has no `double`. Can a double-float type (`df64`, an unevaluated sum of two floats) stand in for `mixed` so that the Common kernels compile unchanged, how accurate is it, and what does it cost on the M2?

## Method

- `df64.metal` is a prelude fragment. It defines `df64`, `df64_2/3/4`, the operators and math functions the Common kernels call, and the IEEE binary64 conversions. The arithmetic uses error-free transformations: TwoSum, and TwoProd through `fma`. The algorithms and their bounds come from Joldes, Muller and Popescu (JMP, ACM TOMS 44(2), 2017), with the bounds as formally proven by Muller and Rideau (MR, ACM TOMS 48(1), 2022); sqrt comes from Lefèvre et al. (TOMS 2023). Every df64 value is a double-word number in the JMP sense, hi = RN(hi + lo): the operations, comparisons and bounds all assume that. exp uses a three-part ln2 reduction with a degree-7 series and five doublings. log is `y + log1p(x*exp(-y) - 1)` starting from a float y.
- There are two storage modes:
  - **pairs**: device memory holds (hi, lo), so the host converts on upload and download with `df64_convert.metal`.
  - **IEEE** (`DF64_IEEE_STORAGE`): device and constant memory hold real IEEE doubles. Address-space constructors decode on every load, and `operator= device` encodes on every store. Kernel code sees `df64` in both modes.
- `harness.swift` runs everything on the GPU with MSL 3.1 and `mathMode = .safe`. `run.sh` drives it. The runs were on the Mac mini M2 (10 GPU cores), macOS 27.0 (26A428); the timing runs only with no build running (checked with `pgrep ninja|clang|cc1plus` before and after).
  - a. Every df64 operation is compared with CPU double over 2^20 random inputs per row at MD magnitudes. Inputs are double-word pairs split from doubles by the decode rule. Error is `|gpu - ref| / |ref|` in units of 2^-48. Comparisons, narrowing to float and double-word form are checked on operands decoded on the GPU from 2^20 doubles, half of them placed next to a float tie.
  - b. The conversion kernels are checked bit for bit against a CPU reference. Decode is `hi = RN(d)`, `lo = RN(d - hi)`, except that a lo of exactly half an ulp of an odd hi moves one float towards zero; encode is `RN(hi + lo)`. The inputs are 42 special doubles, four sets of 2^20 random doubles (one of them next to float ties), 16 edge pairs, and 2^20 random pairs over the whole float range.
  - c. A compile census covers the 36 Common kernel files that mention `mixed` (OpenMM 3c9effc96, pulled by `fetch-kernels.sh`). Each program is the 005 prelude with the precision block replaced as OpenCLContext does in mixed mode: `USE_MIXED_PRECISION`, `SUPPORTS_DOUBLE_PRECISION`, `mixed` = df64, and `double` mapped to df64. The 002 defines and the 005 rewrites are applied.
  - d. The unmodified Common `verlet.cc` and `langevinMiddle.cc` kernels are timed at 23,558 and 173,112 atoms in four variants: single (no USE_MIXED_PRECISION), float mixed (USE_MIXED_PRECISION with mixed = float, so the posqCorrection traffic is included), df64 pairs and df64 IEEE. Float mixed is the baseline for the cost of df64. Variants and kernels are interleaved in a shuffled order each round, over 21 rounds. There is also one numerical Verlet step against CPU double.

## Result

Raw logs:

- M2:
  - `results-AppleM2-20260922T233253Z.md`: full run (a, b, c). Its timing section is marked contended, because a build started during it, and is superseded.
  - `results-AppleM2-20260922T233633Z.md`: timing (d), uncontended.
  - `results-AppleM2-20260922T233811Z.md`: conversion (b) with the max-decode-error column.
- M3 Pro (MacBook Pro): `results-AppleM3Pro-20260922T233434Z.md`, full run, uncontended. Its correctness results match the M2 except for the log rows (max 6.41 and 7.55 instead of 6.64 and 7.99) and the float sqrt count (1,146,376 instead of 1,311,365 not correctly rounded).
- `results-AppleM2-20260922T230510Z.md`, `...230801Z.md` and `results-AppleM3Pro-20260922T230841Z.md` are from before the fixes below.

### a. Accuracy (M2, 2^20 inputs per row, units of 2^-48, flag above 2^-44 = 16)

| Operation | Inputs | Median | Max | Proven bound | > 2^-44 |
| --- | --- | ---: | ---: | --- | ---: |
| df64 + df64 | +-[1e-4, 1e7] | 0.10 | 2.23 | 3u^2 + 13u^3 (JMP Thm 3.1) | 0 |
| df64 + df64, position + step | +-[1e-3, 1e3] + +-[1e-9, 1e-2] | 0.10 | 2.22 | 3 | 0 |
| df64 + df64, cancellation | b = -a(1+d), d in [2^-40, 2^-8] | 0 | 0 | 3 | 0 |
| df64 - df64 | +-[1e-4, 1e7] | 0.10 | 2.25 | 3 | 0 |
| df64 * df64 | +-[1e-4, 1e7] | 0.23 | 3.36 | 4u^2 (MR Thm 2.8) | 0 |
| df64 / df64 | +-[1e-4, 1e7] | 0.30 | 6.80 | 15u^2 + 56u^3 (JMP Thm 7.1) | 0 |
| df64 + float | +-[1e-4, 1e7] | 0.04 | 1.90 | 2u^2 (JMP Thm 2.2) | 0 |
| df64 * float | +-[1e-4, 1e7] | 0.12 | 1.70 | 2u^2 (JMP Thm 4.3) | 0 |
| df64 / float | +-[1e-4, 1e7] | 0.13 | 2.70 | 3u^2 (JMP Thm 6.2) | 0 |
| sqrt | [1e-6, 1e7] | 0.12 | 2.97 | 25/8 u^2 (Lefèvre et al.) | 0 |
| exp | [-60, 60] | 0.17 | 2.59 | none | 0 |
| exp, Langevin scale | [-0.1, 0] | 0.07 | 0.87 | none | 0 |
| log | [1e-6, 1e7] | 0.10 | 6.64 | none | 0 |
| log near 1 | 1 +- [1e-9, 0.5] | 0.53 | 7.99 | none | 0 |
| df64(long), fixed-point force | +-[1, 2^62] | 0 | 0.50 | 0.5 | 0 |
| df64 * long, force scale | dt/2^32 * +-[1, 2^50] | 0.18 | 3.41 | 4 + conversion | 0 |

u = 2^-24, so u^2 is one unit. The bounds hold while no intermediate result over- or underflows.

- The bound citations are exact:
  - JMP Theorem 5.4 gave 5u^2 for DWTimesDW3; MR Theorem 2.8 proves 4u^2.
  - JMP Theorem 7.1 proves 15u^2 + 56u^3 for DWDivDW2 with DWTimesFP1 at its line 2. JMP only remark that the FMA product DWTimesFP3 can be used there "without changing much the error bound", with no proof. `operator/(df64, df64)` used DWTimesFP3; it now uses DWTimesFP1, so the proven bound applies. The measured max is 6.80 either way; the median moved from 0.28 to 0.30.
- Comparisons, narrowing and double-word form, on operands decoded on the GPU from 2^20 doubles (half within 32 double ulps of a float tie of an odd hi; the second operand is the same double, a neighbouring double or float, or unrelated):
  - decoded pairs that are not double-word numbers: 0; pairs that differ from the CPU split: 0
  - comparisons (<, <=, ==, >, >=, !=) that disagree with exact comparison of the decoded values: 0
  - `(real) mixed` differing from RN(d) of the source double: 0
  - pairs where `x + 0`, `x + 0.0f`, `x * 1.0f` or `x * df64(1)` is not the same pair: 0
- Every row stays within its proven bound. Three defects showed up and are fixed in `df64.metal`:
  - The decoder, which every IEEE-storage load runs, returned pairs that are not double-word numbers. Just below a float tie with an odd hi, RN(d - hi) rounds up to exactly half an ulp, and hi + lo then rounds away from hi. For example, d = 1 + 2^-23 + 2^-24 - 2^-52 decoded to (1 + 2^-23, 2^-24), and x + 0 returned (1 + 2^-22, -2^-24), so x == x + 0 was false and x < x + 0 was true. The independent verification found it. Run against the old `df64.metal`, the check above reports 132,025 non-double-word decodes, 5,235 wrong comparisons and 126,778 pairs changed by x + 0; the fixed decoder gives 0 on all of them. The fix keeps hi = RN(d), so `(real) mixed` still equals OpenCL's `(float)` of the double, and moves lo one float towards zero. That costs up to 2^-48 relative decode error on those doubles, instead of 2^-49 (b).
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

| Set | Doubles | Decode bit-exact | Decoded double-word pairs | Encode = RN(hi+lo) bit-exact | Representable | Representable round trips exact | Max decode error (2^-48 units) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Random 64-bit patterns (NaN, inf, subnormal, all exponents) | 1,048,576 | 1,048,576 | 1,048,576 | 1,048,576 | 481,314 | 481,314 | 0.50 |
| Exponent uniform in [-160, 140] | 1,048,576 | 1,048,576 | 1,048,576 | 1,048,576 | 244,295 | 244,295 | 0.50 |
| MD magnitudes +-[1e-4, 1e7] | 1,048,576 | 1,048,576 | 1,048,576 | 1,048,576 | 196,516 | 196,516 | 0.50 |
| Within 32 double ulps of a float tie, odd hi, exponents -140..127 | 1,048,576 | 1,048,576 | 1,048,576 | 1,048,576 | 57,334 | 57,334 | 0.94 |

- All 42 special doubles pass: ±0 (sign kept), ±inf, quiet, signaling and payload NaN (payload not kept, sign kept), subnormal doubles (to signed zero), the float subnormal edges 2^-150 (a tie, to 0) and 2^-149, ties to even in hi, the fast/slow path edges 2^-74 and 2^-75, lo leaving the normal range at 2^-102, and three doubles just below a tie of an odd hi (one with a subnormal lo).
- Near FLT_MAX: just below the tie, a value decodes to (FLT_MAX, 2^103 - 2^79), a double-word pair that encodes back to a finite double. At the tie and above, it decodes to inf.
- "Representable" means the double equals hi + lo exactly, or is NaN, or overflows float. Other doubles lose their bits below 2^-49 relative on the first decode (max 0.50 units), or below 2^-48 next to a tie of an odd hi (max 0.94 units). After the first decode, decode and encode are stable on every set: decode(encode(decode(x))) = decode(x), up to the sign of a zero lo.
- Encode is exact for every double-word pair and for unnormalized pairs with |lo| <= |hi|, including pairs whose float sum overflows although hi + lo is a finite double. The encoder used to skip renormalizing those and then overflowed its integer significand: (FLT_MAX, 2^126), (-FLT_MAX, -2^126), (1.9 × 2^127, 0.2 × 2^127) and (FLT_MAX, 2^104 (1 + 2^-23)) were wrong. They now take the integer path. Two conventions for pairs that are not double-word numbers are now explicit: (0, lo) encodes lo (it used to give 0), and a non-finite lo gives the float sum hi + lo, so (1, NaN) is NaN and (1, inf) is inf (they used to give 1). No df64 operation or decode produces such pairs.
- 16 edge pairs, including those above, all match RN(hi + lo). 2^20 random pairs with hi over all finite floats, in four classes of 2^18, all encode bit-exact: double-word pairs; |lo| up to 4 ulp(hi); |lo|/|hi| log-uniform in [2^-60, 1]; and |hi| >= 2^126 with |lo|/|hi| in [2^-30, 1]. The previous generator kept |hi| <= FLT_MAX/4, so it never reached the overflow cases.
- Apple GPUs flush float subnormals to zero, both as inputs and as results. On both chips the log shows `2^-140 * 1 = 0`, `2^-70 * 2^-70 = 0`, and `2^-140 != 0` false. The first encoder failed on 4.5% of random pairs whose lo was subnormal, or whose renormalization error was subnormal. It also turned the pair just below FLT_MAX into inf. These cases now take the integer path.
- For arithmetic, the same flushing means df64 has full precision only down to about 2^-102 (1e-31). Below that, lo is flushed and precision drops towards float. That is far below MD magnitudes.
- Cost of converting a velm-sized array in place (GPU clock, median of 21):
  - 4.1 µs (decode) and 4.7 µs (encode) at 23,558 atoms
  - 69 µs each way at 173,112 atoms (5.5 MB). Each command buffer converts the same array 200 times, so this is probably cache-resident (M2 system-level cache 8 MB, not measured): reading and writing 5.5 MB in 69 µs is 160 GB/s, above the M2's 100 GB/s DRAM bandwidth. A single cold conversion would cost more.

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

Clock: GPU (`MTLCommandBuffer.gpuEndTime - gpuStartTime`). Each command buffer holds one compute encoder with 200 repetitions, in µs per call. Every round measures each (variant, kernel) cell once, in a freshly shuffled order, after one untimed warm-up round. Cells are the median over 21 rounds, with the interquartile range in brackets. The kernels are the unmodified Common sources. The run was uncontended: no ninja, clang or cc1plus before or after, and it started only after two idle polls a minute apart.

The baseline is float mixed: USE_MIXED_PRECISION with `mixed` = float, which reads and writes posqCorrection as the df64 variants do. The earlier "single" baseline has no posqCorrection traffic: float mixed is 19 to 38% slower than single, so ratios against single overstate the cost of df64 by that much.

| Integrator, whole step | Atoms | single | float mixed | df64 pairs | df64 IEEE | pairs / float mixed | IEEE / float mixed |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Verlet (Part1 + Part2) | 23,558 | 9.1 [9.1-9.9] | 11.5 [10.6-11.7] | 39.6 [37.4-42.6] | 87.3 [85.7-91.8] | 3.45 | 7.62 |
| LangevinMiddle (Part1-3) | 23,558 | 16.2 [14.9-16.5] | 22.3 [20.7-23.6] | 69.1 [65.7-69.4] | 138.7 [133.0-140.4] | 3.09 | 6.20 |
| Verlet | 173,112 | 307.0 [299.1-307.5] | 392.2 [385.2-394.2] | 615.6 [613.5-616.6] | 700.7 [696.0-704.8] | 1.57 | 1.79 |
| LangevinMiddle | 173,112 | 404.4 [396.8-405.1] | 480.3 [471.9-483.0] | 884.2 [879.3-885.8] | 1041.6 [1033.1-1044.4] | 1.84 | 2.17 |

- The whole-step interquartile ranges reach at most 9% from the median at 23k and 3% at 173k. The widest cell is single Verlet Part2 at 173k (89-130 µs, whole step unaffected). Across the ranges the 23k ratios move by up to about 15% (Verlet IEEE 7.3 to 8.7) and the 173k ratios by under 5%, which changes no conclusion.
- At 173k atoms the kernels are bandwidth-bound, and df64 costs about what the doubled mixed arrays cost. At 23k atoms they are latency- and ALU-bound, and IEEE decode/encode roughly doubles the df64 cost.
- The M3 Pro is cheaper for df64: 1.56 and 1.68 (pairs) and 3.40 and 3.70 (IEEE) at 23k, and 1.76 to 2.26 at 173k, against float mixed.
- Per-kernel rows are in the raw log, for attribution only. Whole step against the sum of its kernels timed alone:

| Integrator | Atoms | single | float mixed | df64 pairs | df64 IEEE |
| --- | ---: | ---: | ---: | ---: | ---: |
| Verlet | 23,558 | 0.94 | 1.06 | 1.16 | 1.03 |
| LangevinMiddle | 23,558 | 1.13 | 1.43 | 1.04 | 1.09 |
| Verlet | 173,112 | 1.04 | 1.01 | 1.02 | 1.03 |
| LangevinMiddle | 173,112 | 1.07 | 1.08 | 1.03 | 1.05 |

- The earlier run measured the cells in a fixed order with no warm-up, and single Verlet Part1 alone took 9.4 µs, about as much as the whole step. With shuffling and a warm-up round it takes 5.0 µs, the same as float mixed. That anomaly was measurement order.
- At 173k the whole step is 1 to 8% slower than its parts on the M2 (up to 33% on the M3 Pro). A kernel repeated alone rereads the same arrays, so that is consistent with more of them staying in the caches, but cache residency was not measured.
- At 23k the ratios run from 0.94 to 1.43 (float mixed LangevinMiddle), and there is no explanation for them. Each call is 4 to 50 µs, so fixed dispatch costs and clock state are a large share of it, and the arrays (about 3 MB) should fit in the 8 MB system-level cache whether a kernel runs alone or in a step. The whole-step rows are the figures to use.

One Verlet step at 23,558 atoms against CPU double (normwise error, max |err| / max |ref|):

| Mode | Velocity | Position (posq + posqCorrection) |
| --- | ---: | ---: |
| single | 1.0e-7 | 4.8e-8 |
| float mixed | 1.0e-7 | 4.8e-8 |
| df64 pairs | 1.1e-14 | 1.4e-15 |
| df64 IEEE | 1.1e-14 | 1.4e-15 |

- IEEE and pair storage differ by at most 6e-16 (normwise). That is the extra rounding to 53 bits when a pair spans more than 53 bits.
- The velocity error is about 2^-46 normwise. It includes the 2^-49 split of the double inputs and dt.

The same costs in whole-step terms, using the 014 OpenCL single step times (host wall clock: dhfr 2.53 ms/step, nav 15.8 ms/step), as time added over float mixed:

| Work unit | Integrator | Added by df64 pairs | Added by df64 IEEE | IEEE over pairs |
| --- | --- | ---: | ---: | ---: |
| dhfr, 23,558 | Verlet | +28.1 µs (+1.1%) | +75.8 µs (+3.0%) | +47.7 µs (+1.9%) |
| nav, 173,112 | LangevinMiddle | +403.9 µs (+2.6%) | +561.3 µs (+3.6%) | +157.4 µs (+1.0%) |

These percentages combine a GPU clock with a host clock, and they cover only the integration kernels. Not measured: the other mixed-precision kernels in a step (constraints: SETTLE/CCMA, center-of-mass removal, kinetic energy, barostat), and the Metal platform's own step time.

## What it changes

- **Mixed precision is possible on Apple GPUs without fp64.**
  - df64 meets every proven error bound (JMP 2017, MR 2022, Lefèvre et al. 2023; division now uses the exact algorithm the proof covers). Its worst measured relative error is 8.0 × 2^-48 ≈ 2^-45 (log near 1, no proven bound), 6.8 × 2^-48 for division, and at most 3.4 × 2^-48 for the other operations, against the 2^-53 of real double.
  - The IEEE conversions are exact to their contract: decode gives a double-word pair with hi = RN(d) (error up to 2^-49, or 2^-48 next to a float tie of an odd hi), and encode gives RN(hi + lo) for every double-word pair and for unnormalized pairs with |lo| <= |hi|, including those whose float sum overflows.
  - It compiles 31 of the 36 mixed Common kernel files as they are, and 33 with 8 literal edits in Common.
  - Against float mixed on the M2, it costs 1.6 to 3.5x in the integration kernels with pair storage, or 1.8 to 7.6x with IEEE storage. That is 1 to 4% of a Folding@home step.
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
  - At 23k atoms the whole step and the sum of its kernels disagree by up to 43% (d), without an explanation. The bulk conversion figures are probably cache-resident.
  - LocalEnergyMinimizer under mixed on Metal throws, as it does on any device without 64-bit atomics. Whether the Folding@home core calls it is unverified.

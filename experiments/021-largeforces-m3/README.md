# 021 testLargeForces on M3 (#5434): out-of-range float to long conversion wraps

## Question

`testLargeForces` (tests/TestLocalEnergyMinimizer.h:199-231) fails at `ASSERT(maxdist > 1.0)` (:229) on the M3 Pro and the M3 Ultra. It fails for Metal single and mixed, and for OpenCL single on unmodified 3c9effc96. It passes on the M2 (016 NOTES, 2026-09-23). Both stacks fail the same way, so the cause is probably in the GPU or its compiler, not in platform code. What is the mechanism?

## Answer

On the M3 Ultra, converting a float to a signed 64-bit integer when the value is outside the int64 range gives the exact integer value modulo 2^64. The M2 saturates to INT64_MAX or INT64_MIN. Metal and OpenCL behave the same on each chip. `realToFixedPoint` is `(long) (x*0x100000000)` in both common.metal:130-132 and common.cl:81-83, and it silently depends on saturation:

1. The test's initial forces are 2e22 to 4e26 kJ/mol/nm. Times 2^32 that is at least 2^106. A float that large is a multiple of 2^64, so modulo 2^64 it becomes exactly **0**.
2. With saturation (M2), every component is ±2^63. `convertForces` (minimize.cc) sees |f| > 2^62, sets `returnValue = FLT_MAX`, and the minimizer falls back to the CPU for that step. With wrapping (M3), every force is 0. No overflow is flagged, and the energy, 1.37e23, is still below FLT_MAX, so the energy check does not catch it either.
3. `lbfgs()` then runs `gradNormKernel`, gets 0 <= tolerance and returns before the first iteration. The positions never move. maxdist stays at its starting value of 0.01315 and the test fails.

The reproducer shows all three steps on the M3 Ultra. Every force component that `getState` reads back is exactly 0.000000000e+00. The reporter is called zero times. The final energy equals the initial energy bit for bit (1.374907623e+23). Replacing only `realToFixedPoint` with a saturating version makes the test pass on the M3 Ultra: Metal single, Metal mixed and OpenCL single, 3 of 3 each. That was done by patching copies of the installed plugins, with no rebuild (section 5). The trajectory then follows the M2's. Every patched run has 79 reporter calls, as the M2 runs do. OpenCL iteration 0 matches the M2 in every printed digit (E 9.783949606e+19, |g| 3.369207e+23). Metal iteration 0 is within 4e-6 relative, which is inside the run-to-run spread of the final energies.

Root cause: **proven** for this test on the M3 Ultra, down to the bit. For the M3 Pro it is inferred, not measured, because the owner has ruled out GPU runs on the laptop. Its failure is the same assertion on the same stacks. It also rules out the OS build as the cause: the laptop runs macOS 27.0 26A428, the same build as the passing M2 mini. That leaves GPU family (Apple9 against Apple8), in the hardware or in the driver's per-family code generation. These probes cannot tell the two apart.

## Hypotheses

| | Hypothesis | Verdict | Evidence |
| --- | --- | --- | --- |
| a | Float atomic add rounds toward zero on M3 but to nearest even on M2 | **Refuted** | 2^20 uncontended `atomic_fetch_add` on `atomic_float`, one thread per cell, compared with host round-to-nearest-even and round-toward-zero. Both chips match RNE on 1,048,576 of 1,048,576, and match RTZ on 0 of the roughly 490k cases where the two differ. A plain float add gives the same result. The hypothesis also could not explain the OpenCL failure, since OpenCL's single-precision `atomicAddMixed` is a compare-exchange loop around an ordinary add. And the test has 30 variables, so every reduction kernel runs as a single threadgroup (`MetalKernel::execute`, `OpenCLContext::executeKernel`). Each `atomicAddMixed` therefore adds once into a zeroed cell, which is exact in any rounding mode. |
| b | Out-of-range float to long conversion differs by chip | **Confirmed, root cause** | Table below |
| c | Instrument the minimizer and find the first divergence | Done | The two chips diverge in the very first force evaluation, before any minimizer arithmetic: M2 reads back ±2.147483648e+09 (±2^63 / 2^32) for every component, M3 Ultra reads 0 |
| c' | Forcing SINGLE_BLOCK_REDUCTIONS in single precision fixes it | **Moot** | The failure is decided before any reduction. The gradient is 0 at the first `gradNormKernel`, which already runs as a single block, and the loop is never entered |

## Probes

All probes compile the MSL with the MetalContext.cpp options (MSL 3.1, `MathModeSafe`) or the OpenCL build options from OpenCLContext.cpp (`-cl-mad-enable -cl-no-signed-zeros`). Inputs come from buffers, so nothing is constant-folded.

- `probes/conversion-metal.swift`, `probes/conversion-opencl.c`: `(long)(x*0x100000000)` (that is, `realToFixedPoint`), `(long)x`, `(ulong)x`, `(int)x`, `(uint)x` and OpenCL `convert_long_sat` for 32 inputs from 0 through ±2^31, ±2^63, ±FLT_MAX, ±inf and NaN. The Metal probe runs with `fast` as well.
- `probes/classify-conversions.py`: checks every conversion in those outputs against two models, "exact value mod 2^64" and "saturate".
- `probes/atomic-rounding-metal.swift`: hypothesis a.
- `probes/largeforces.cpp`: testLargeForces verbatim (same SFMT seed, system and call), plus a dump of the initial forces and one line per minimizer iteration from a `MinimizationReporter`. Linked against the existing f9347f6c5 installs (mini `~/lab/qa-f934/prefix`, Studio `/tmp/openmm-metal-bench/prefix`).
- `probes/fixedpoint-fix-metal.swift`, `probes/fixedpoint-fix-opencl.c`: run the current conversion and the proposed fix over 2^20 random float bit patterns covering the whole exponent range, plus NaN. Each result is compared with a host reference that truncates toward zero and saturates.
- `probes/patch-metal.pl`: a same-length patch of the `common.metal` text embedded in a copy of `libOpenMMMetal.dylib`. It deletes the erf doc comment to make room for the saturating `realToFixedPoint`. The OpenCL copy was patched with a same-length perl substitution: `    return (long) (x * 0x100000000);` became ` return convert_long_sat(x*0x1p32f);`, and exactly 32 bytes differ. Both copies were re-signed ad hoc (`codesign -f -s -`) and loaded through `OPENMM_PLUGIN_DIR`. The installed prefix was not modified.
- `lane/lane.sh`: the Studio driver for section 6. It builds the base and fix branches, runs CTest, and times fahwu, taking the lease separately for each step. `lane/fahwu.py` is an unmodified copy of `017-three-chips/fahwu.py`, so the Studio run has it next to the driver.

Machines: Mac mini M2 (10 GPU cores), macOS 27.0 26A428, `~/lab/021-largeforces-m3`. Mac Studio M3 Ultra, macOS 27.2 26B5091g, `/tmp/openmm-metal-bench/021`. The M2 conversion, atomic and minimizer probes ran before the shared-lease rule existed; every later run on either machine held that machine's lease. Raw outputs are in `raw/`, prefixed `m2-` and `m3u-`. No GPU work ran on the laptop.

## 1. Conversion results (bit patterns, from `raw/*-conversion-metal-safe.txt`, `raw/*-conversion-opencl.txt`)

Metal and OpenCL give identical bits on each chip. `mathMode` fast and safe are also identical.

| x (float) | x*2^32 | M2 `(long)(x*2^32)` | M3 Ultra `(long)(x*2^32)` | M3 Ultra `convert_long_sat` (OpenCL) |
| --- | --- | --- | --- | --- |
| 1.0737418e9 (2^30) | 2^62 | 0x4000000000000000 | 0x4000000000000000 | 0x4000000000000000 |
| 2.1474835e9 (largest float below 2^31) | < 2^63 | 0x7fffff8000000000 | 0x7fffff8000000000 | 0x7fffff8000000000 |
| 2.1474836e9 (2^31) | 2^63 | 0x7fffffffffffffff | **0x8000000000000000** (sign flip) | 0x7fffffffffffffff |
| -2.1474839e9 | -(2^63+2^40) | 0x8000000000000000 | **0x7fffff0000000000** (sign flip) | 0x8000000000000000 |
| 4.0e9 | ≈1.7e19 | 0x7fffffffffffffff | **0xee6b280000000000** | 0x7fffffffffffffff |
| 1.0e10 | ≈4.3e19 | 0x7fffffffffffffff | **0x540be40000000000** | 0x7fffffffffffffff |
| 4.611686e18 and up (incl. the test's forces) | ≥ 2^94 | 0x7fffffffffffffff | **0x0000000000000000** | 0x7fffffffffffffff |
| -1.0e20 | ≈ -4.3e29 | 0x8000000000000000 | **0x0000000000000000** | 0x8000000000000000 |
| +inf / -inf | | 0x7fff... / 0x8000... | **0 / 0** | 0x7fff... / 0x8000... |
| NaN | | 0 | 0 | 0 |

`raw/classify-conversions.txt`: on the M3 Ultra, all 64 of 64 conversions (`(long)(x*2^32)` and `(long)x`, Metal and OpenCL) equal the exact truncated value mod 2^64. On the M2, all 64 of 64 saturate. The 32-bit conversions `(int)`, `(uint)` and the unsigned `(ulong)` saturate on both chips; only float to signed 64-bit wraps on the M3.

## 2. Minimizer traces (`raw/*-Metal-*.txt`, `raw/*-OpenCL-single*.txt`)

| Chip / stack | initial forces read back | reporter iterations | final E | maxdist | result |
| --- | --- | --- | --- | --- | --- |
| M2 Reference (double) | 2e22 to 4e26, finite | 78 | 27.29 | 2.355 | PASS |
| M2 CPU | | 78 | 27.29 | 2.355 | PASS |
| M2 Metal single | all ±2.147483648e+09 | 79 | 19.88 | 3.212 | PASS |
| M2 Metal mixed | all ±2.147483648e+09 | 79 | 19.88 | 3.212 | PASS |
| M2 OpenCL single | all ±2.147483648e+09 | 79 | 19.88 | 3.212 | PASS |
| M3 Ultra Metal single | **all 0** | **0** | 1.374907623e+23 (= initial) | 0.01315 | FAIL |
| M3 Ultra Metal mixed | **all 0** | **0** | 1.374907501e+23 (= initial) | 0.01315 | FAIL |
| M3 Ultra OpenCL single (3 runs) | **all 0** | **0** | 1.374907623e+23 (= initial) | 0.01315 | FAIL 3/3 |

M2 OpenCL mixed: "No compatible OpenCL platform" (no fp64), as in 016.

## 3. Atomic rounding (`raw/*-atomic-rounding.txt`)

| Chip | `atomic_fetch_add` matches RNE | matches RTZ where RNE ≠ RTZ | plain add matches RNE |
| --- | --- | --- | --- |
| M2 | 1,048,576 / 1,048,576 | 0 / 490,016 | 1,048,576 / 1,048,576 |
| M3 Ultra | 1,048,576 / 1,048,576 | 0 / 490,410 | 1,048,576 / 1,048,576 |

## 4. Proposed fix

Saturate explicitly and stop depending on the conversion.

Metal, `platforms/metal/src/kernels/common.metal:130-132` (real is always float on Metal):

```c
inline long realToFixedPoint(real x) {
    real v = x*0x1p32f;
    return v < -0x1p63f ? LONG_MIN : v >= 0x1p63f ? LONG_MAX : (long) v;
}
```

OpenCL, `platforms/opencl/src/kernels/common.cl:81-83` (also covers `real` = double):

```c
inline long realToFixedPoint(real x) {
    return convert_long_sat(x * 0x100000000);
}
```

Kernel-level check (`raw/*-fix-*.txt`): 2^20 random float bit patterns plus NaN, compared with the saturating reference.

| | M3 Ultra current | M3 Ultra fixed | M2 current | M2 fixed |
| --- | --- | --- | --- | --- |
| Metal, disagreements with reference | 396,953 (0 in range) | **0** | 0 | **0** |
| OpenCL `convert_long_sat` | 395,641 (0 in range) | **0** | 0 | **0** |
| OpenCL explicit compares (same as the Metal fix) | | **0** | | **0** |
| NaN | 0 | 0 | 0 | 0 |

The fix changes no in-range value on either chip (0 in-range disagreements), and NaN stays 0, which is what the M2 does today.

## 5. End-to-end with the fix (M3 Ultra, patched plugin copies, `raw/m3u-*-patched-run*.txt`)

| Stack | unpatched | patched |
| --- | --- | --- |
| OpenCL single | FAIL 3/3 (maxdist 0.01315) | **PASS 3/3** (maxdist 3.2124, 3.2124, 3.2123; 79 iterations) |
| Metal single | FAIL | **PASS 3/3** (maxdist 3.2124, 3.2123, 3.2124) |
| Metal mixed | FAIL | **PASS 3/3** (maxdist 3.2124, 3.2123, 3.2123) |

With the patch the initial forces read back as ±2.147483648e+09, exactly as on the M2.

## 6. Fix branches, built and tested (M3 Ultra, `results-fix/`)

Two branches in `openmm-metal`, not pushed:

| Branch | Base | Commit | Change |
| --- | --- | --- | --- |
| `metal-fixed-point-sat` | `metal` 361452c5c | 556fbad21 | Saturating `realToFixedPoint` in `common.metal` (explicit compares), plus the common kernels. 6 files, +26/-21 |
| `opencl-fixed-point-sat` | 3c9effc96, the merge-base of `metal` and upstream `master` | 0e0a66cfe | `convert_long_sat` in `common.cl`, plus the same common kernels. 6 files, +23/-21. This is the upstream fix for #5434 |

Both branches route the five direct-cast sites in `platforms/common/src/kernels` through the platform's `realToFixedPoint`, so each branch has one helper. The sites are `customCppForce.cc`, `pythonForce.cc`, `minimize.cc` `getConstraintEnergyForces`, `atmforce.cc` and `customCentroidBond.cc`. The last two already hold fixed-point values. They scale back by 2^32 before the call, so the sum or the weighted value saturates instead of wrapping. The brief named f9347f6c5 as the merge-base, but that commit is on `metal`. The true merge-base with `origin/master` is 3c9effc96, so the OpenCL branch starts there.

Each branch was exported with `git archive` to `/tmp/openmm-metal-bench/021/src` on the Studio, where `lane/lane.sh` built it. Every step held the Studio lease on its own, and the longest hold was 5 min 04 s. The embedded kernel sources were checked for the new `realToFixedPoint` and for 16 routed call sites in `CommonKernelSources.cpp` on `fix` and `oclfix`, with 0 on `base`.

Host: Apple M3 Ultra, macOS 27.2 (26B5091g).

| Run | Result | Wall time |
| --- | --- | --- |
| `ctest -R '^TestMetal.*Single$' -j 4` | **55/55 passed** | 206.30 s |
| `ctest -R '^TestMetal.*Mixed$' -j 4` | **55/55 passed** | 303.74 s |
| `TestOpenCL{LocalEnergyMinimizer,CustomCentroidBondForce,ATMForce}Single`, 3 runs | **3/3 passed each run** | 22.57, 16.23, 18.82 s |

`TestMetalLocalEnergyMinimizerSingle` took 8.25 s and `TestMetalLocalEnergyMinimizerMixed` took 22.48 s. `TestOpenCLLocalEnergyMinimizerSingle` took 14.41, 14.42 and 16.95 s. Before the fix all three fail on this machine (section 2). The ATM, CustomCentroidBond and PythonForce tests also pass on Metal in both precisions. The last of these covers the `pythonForce.cc` kernels. The OpenCL build only compiled the three tests above, not the full OpenCL suite.

Cost, from `results-fix/timing.jsonl`: `fahwu.py`, Metal single, 30 s per run. The clock is `fahwu.py`'s host wall clock (`time.perf_counter`) over whole steps. Base (361452c5c) and fix (556fbad21) were interleaved over 2 rounds, base first in round 1 and fix first in round 2.

| WU | Round | base ns/day | fix ns/day | fix / base |
| --- | --- | --- | --- | --- |
| dhfr (23,558 atoms) | 1 | 126.70 | 126.43 | 0.998 |
| dhfr | 2 | 128.27 | 128.79 | 1.004 |
| nav (173,112 atoms) | 1 | 44.86 | 44.69 | 0.996 |
| nav | 2 | 44.84 | 44.94 | 1.002 |
| **mean** | | dhfr 127.48, nav 44.85 | dhfr 127.61, nav 44.82 | **dhfr 1.001, nav 0.999** |

The fix costs nothing measurable. The fix/base ratio changes sign between rounds, and each difference is smaller than the 1.2-1.9% drift of a single variant between rounds. Energies and force errors against the reference match between base and fix on both WUs.

## Risks and follow-ups

- **`minimize.cc` precision in mixed mode.** `getConstraintEnergyForces` used to scale in `mixed`. It now calls `realToFixedPoint`, which takes `real`. On Metal mixed and OpenCL mixed this narrows `kdr*delta` from df64/double to float before the conversion, which matches how every other force reaches the buffer. Double mode is unchanged, since `real` is double there. `TestMetalLocalEnergyMinimizerMixed` passes, but no test measures that precision directly.
- `df64::operator long` (Metal mixed) is `(long)hi + (long)lo`, and it wraps in the same way. After this change no fixed-point path uses it. Any future caller needs the same saturation.
- The fix is covered by the CTest binaries above, and before that by `largeforces.cpp`, which runs the test body verbatim on patched plugins (section 5). The full OpenCL suite was not run on either branch.
- Saturation is only a signal. A saturated contribution plus other contributions to the same atom can still wrap in the 64-bit atomic sum, on every GPU. That is pre-existing upstream behaviour and not part of this issue.
- The M3 Pro was not probed (owner's rule), so M3 Pro wrapping is inferred from its identical failure. The laptop can confirm it in 2 seconds with `conv-metal` whenever GPU use is allowed there again.
- The probes cannot tell hardware from driver per-family code generation. One sign of software lowering on Apple9: 32-bit and unsigned 64-bit conversions saturate, and only signed 64-bit wraps. Either way the upstream fix is the same, since MSL and OpenCL C both leave out-of-range conversions undefined, apart from `convert_*_sat`.
- For the upstream issue: CUDA's `static_cast<long long>` saturates on NVIDIA hardware (per the PTX `cvt` specification, not verified here), and the HIP float path hand-rolls its conversion. That explains why only Apple M3 exposes the dependence.

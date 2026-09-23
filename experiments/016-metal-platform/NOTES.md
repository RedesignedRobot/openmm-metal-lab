# 016 — Native Metal platform (milestone A, single precision)

Working copy: `~/code/mini/openmm-metal`, branch `metal` (off 3c9effc). Mini: M2, 10 GPU cores, 8 GB,
macOS 27, CLT only. Build prefix `~/lab/prefix-openmm-metal`, Python `~/lab/venv-metal`.

## Running log

### 2026-09-23 — host code complete, pre-build checks

- MetalNonbondedUtilities converted from the OpenCL version to the ComputeKernel API. Kernel
  arguments are added in order (`addArg()` placeholders for the box arguments), because Metal
  binds by position.
- Interaction count: `downloadCountEvent->enqueue()` after findInteractingBlocks (this commits the
  neighbour-list kernels), a second commit after the nonbonded kernel, then `wait()` and a direct
  read of the shared buffer. No blocking download.
- Local checks before the first mini build:
  - clang++ `-fsyntax-only` on every `platforms/metal/src/*.cpp`: clean, apart from one warning that
    OpenCLContext also has (delete of ComputeForceInfo).
  - MSL harness (`scratchpad/harness/check.py`) assembles each kernel file the way
    `MetalContext::createLibrary` does (defines, prelude, signature rewrite) and compiles it
    with MTLDevice `newLibrary`:
    - sort.metal (uint and float2 traits), findInteractingBlocks.metal (plain, periodic,
      large blocks) and nonbonded.metal (5 configurations) all compile.
    - Common kernels: 41 of 45 non-CPU files compile. The failures are gayBerne.cc and dpd.cc
      (pointers without an address space) plus noseHooverChain.cc and qtb.cc, whose
      host-substituted templates the harness can't fake.
  - Finding: MSL treats an unsuffixed literal like `0.5` as float, so a double literal is not a
    hazard.
  - Finding: `threadgroup` declarations after the rewriter's prologue statements compile.
- Common-code edit: `minimize.cc` `atomicAddMixed` gains an `__METAL_VERSION__` branch
  (float atomic add). Without it the LBFGS minimizer hits its `#error`.

### 2026-09-23 — first mini build and test suite

- Build: CLT only, `ninja -j4`, Release, arm64. Clean after local syntax and MSL-harness checks.
- `ctest -R TestMetal -j1`: 50 of 54 passed (529 s total). The four failures:
  - Checkpoints: the shared `testMultipleDevices` asks for `DeviceIndex "0,0"`, and a Metal context
    only takes one device. Fixed with a guarded edit to `tests/TestCheckpoints.h`: Metal keeps the
    default device. Rerun passes.
  - MonteCarloAnisotropicBarostat: avg pressure 11.07 against 10 ± 10% at line 624. The assert
    says it is stochastic. It passed 3 of 3 reruns, so this was a flake.
  - DPDIntegrator, GayBerneForce: `dpd.cc` and `gayBerne.cc` take pointers to private memory
    (`RandomState*`, `int* neighborBuffer`) without an address space. MSL rejects them
    ("pointer type must have explicit address space qualifier"). Not fixed: both are extras, and
    the fix is a common-kernel change that every platform would need to accept.
- Constraint coverage: CCMA and SHAKE run inside the Verlet and Langevin tests, SETTLE in
  TestSettle. There are no platform serialization tests; Checkpoints is the round-trip test.
- Command batching (TestMetalCommandBatching, 3375 atoms, LangevinMiddle, 100 steps):
  - Commits per step: 1.01 with NoCutoff, 2.01 with PME.
  - The first version used 1000 atoms. Common code only uses a neighbor list above 3000
    particles, so it never exercised the neighbor list.
  - With PME, the neighbor-list event and the pre-wait nonbonded commit are the only non-empty
    commits. The integrator's kernels ride along with the next step's neighbor-list commit, so
    the commit at the end of finishComputation is empty.
- Rerun after the fixes (`ctest -R` on the 5 affected tests): Checkpoints, CommandBatching and
  AnisotropicBarostat pass; DPD and GayBerne fail. Net result: 52 of 54.

### 2026-09-23 — FAH work units (commit afa4268d1, installed into prefix-openmm-metal / venv-metal)

`fahwu.py <wu> <platform> single 60`, run one at a time with no build running. Clock: host wall,
whole steps, after a 200-step warm-up. Errors are against Reference in double precision.
OpenCL is the same build, same session.

| WU | atoms | Metal ns/day | OpenCL ns/day | Metal/OpenCL | Metal force err | OpenCL force err | Metal energy err | OpenCL energy err |
|---|---|---|---|---|---|---|---|---|
| dhfr-implicit (GBSA-OBC) | 2489 | 116.95 | 193.32 | 0.60 | 2.47e-5 | 2.46e-5 | 4.0e-7 | 9.7e-7 |
| dhfr (PME) | 23558 | 64.02 | 68.14 | 0.94 | 1.21e-6 | 1.21e-6 | 1.96e-6 | 1.77e-6 |
| nav (PME) | 173112 | 7.55 | 11.00 | 0.69 | 1.75e-6 | 1.80e-6 | 3.5e-7 | 4.5e-7 |

The OpenCL numbers reproduce the 014 baselines (192.0 / 68.4 / 10.95).

### Experiments (temporary patches, reverted; production build reinstalled afterwards)

Same clock and method, Metal single, 60 s per WU.

| Variant | dhfr-implicit | dhfr | nav |
|---|---|---|---|
| Shipped: batched, precise math functions | 116.95 | 64.02 | 7.55 |
| A: commit after every dispatch (`MetalKernel::execute`) | 104.44 | 49.61 | 7.48 |
| B: batched, `MathFloatingPointFunctionsFast` (MathModeSafe kept) | 159.73 | 79.37 | 10.73 |

- A measures the batching. With per-dispatch commits, TestMetalCommandBatching counts
  6.25 dispatches per step for NoCutoff and 17.75 for PME, against 1.01 and 2.01 commits per
  step when batched. That understates the total: VkFFT dispatches are not counted, and
  neither are blits. Batching is worth +12% on dhfr-implicit and +29% on dhfr. nav is GPU-bound,
  so it gains only 1%.
- B is the surprise: precise math functions are most of the gap to OpenCL.
  - Force and energy error are unchanged (2.46e-5 / 1.20e-6 / 1.78e-6 force).
  - With fast functions Metal beats OpenCL on dhfr (1.16x), matches it on nav (0.98x), and
    reaches 0.83x on dhfr-implicit.
  - OpenCL does not use precise functions everywhere either. OpenCLContext measures
    native_sqrt/rsqrt/recip/exp/log at startup and uses each one whose error is below 1e-6.
  - The brief mandates precise math, so the shipped build keeps it. Decision for milestone B:
    port OpenCL's accuracy probe and use `fast::` per function.
- Remaining dhfr-implicit gap after B: suspected to be the 64-bit fixed-point force atomics,
  which the prelude emulates with two 32-bit atomics plus a carry (the M2 has no 64-bit atomic
  add), and the 12×cores cap on thread blocks. Not measured.

### Code size (platforms/metal, lines incl. license headers)

- Host C++: 4315 (src/*.cpp 2503, include/*.h 1812), plus 78 lines of generated-source templates (.in)
- Kernels: 1095 (sort 306, findInteractingBlocks 394, nonbonded 395)
- Prelude: 131 (common.metal)
- CMake: 145 (platforms/metal), plus the top-level CMakeLists.txt switch
- Tests: 2340 (mostly the thin OpenCL-derived wrappers, plus Sort/FFT/Random/CommandBatching)

### Edits outside platforms/metal

1. `platforms/common/src/kernels/minimize.cc`: `__METAL_VERSION__` branch in atomicAddMixed.
   Without it the LBFGS minimizer hits its `#error`. Since 5f9214a52 the branch is
   `&& !defined(USE_MIXED_PRECISION)`, so mixed falls through to the `#error` (never compiled:
   the host throws first).
2. ~~`tests/TestCheckpoints.h`~~: reverted to upstream in 298cf81b0. Metal no longer has a
   DeviceIndex property, so the shared test takes its existing single-device path.
3. `libraries/vkfft/include/vkFFT.h`: fixes to the Metal backend. It now initializes the
   NSError pointers and the compile options, treats a missing library (not a non-null error) as
   a compile failure, no longer releases autoreleased objects, and (7a9e179b6) checks the compile
   error for null before printing it. All listed for upstream in `libraries/vkfft/METAL_PATCHES.txt`.
4. `CMakeLists.txt`: OPENMM_BUILD_METAL_LIB (ON on Apple arm64 since 281fcec19), the metal subdirectory, and METAL in
   the common-build condition.
5. `platforms/common/src/kernels/noseHooverIntegrator.cc` (7) and `integrationUtilities.cc` (1),
   commit 373424395: `cond ? mixedValue : 0.0f` becomes `: (mixed) 0`. No-op for CUDA/HIP/OpenCL
   (the literal is promoted anyway); needed when mixed is the df64 class.
6. `platforms/common/include/openmm/common/ComputeContext.h`: `doubleToString` is virtual, so
   MetalContext can write double constants that a float can't hold as df64 (see "float fallbacks"
   below). No behaviour change for CUDA/HIP/OpenCL.
   - Upstream risk: this is an ABI change. Making a non-virtual member function virtual changes
     ComputeContext's vtable, so plugins built against an earlier OpenMM's ComputeContext must be
     rebuilt. Upstream would have to accept it in a release that already breaks the plugin ABI, or
     Metal would need another route (for example a hook in the expression code generator).

### 2026-09-23 — room for df64 mixed precision (commit 8dc19ec55)

Follows the 015 integration note.
- `MetalContext::createLibrary` now emits `#include <metal_stdlib>` and `using namespace metal;`
  itself, then `singlePrecisionDefinitions`, then the prelude (`common.metal`).
  - `singlePrecisionDefinitions` is one block: the real/mixed typedefs and the make_real*/make_mixed*
    macros, which are no longer compilationDefines.
  - The block sits before the prelude's `#define thread`. Mixed mode replaces it with 015's
    `precisionBlock(.df64IEEE)`.
- `trimTo3` is now inline functions for float4 and float3, so df64 can overload it.
- SQRT maps to `precise::sqrt`. Under the shipped MathFloatingPointFunctionsPrecise this is the
  same code; the explicit mapping keeps sqrt correctly rounded if the function mode ever changes.
- Still to do for mixed mode, host side:
  - accept "mixed" in the constructor (it throws for anything but "single" today) and set
    useMixedPrecision;
  - Common already allocates mixed arrays at double size;
  - getSupports64BitGlobalAtomics() must become false (correction: at this commit it returned
    true, see 5f9214a52 below);
  - math mode stays Safe.
- Verification:
  - Full `ctest -R TestMetal`: "96% tests passed, 2 tests failed out of 54" (DPD and GayBerne,
    same address-space errors), 414 s.
  - FAH Metal single, host wall clock: dhfr 63.89 ns/day (was 64.02), dhfr-implicit 117.36
    (was 116.95). Errors unchanged.

### 2026-09-23 — fast math functions per accuracy probe (commit 2401c28f9)

- New `kernels/utilities.metal`: `determineFastAccuracy` evaluates fast::sqrt, fast::rsqrt,
  fast::divide(1, x), fast::exp, fast::log on OpenCL's 20 probe values (1e-4·π^k).
- MetalContext's constructor runs it and maps SQRT, RSQRT, RECIP, EXP, LOG each to the fast
  version if its max relative error vs host double is < 1e-6, else the precise one. Compile options
  unchanged (MathFloatingPointFunctionsPrecise, MathModeSafe).
- Local preview on the M3 Pro (Swift, same kernel): sqrt 8.3e-8, rsqrt 5.1e-8, recip 5.1e-8,
  exp 3.2e-7, log 1.5e-7; all pass. **Superseded by 4ac98bb16: SQRT stays `precise::sqrt`
  (team-lead decision); only RSQRT, RECIP, EXP, LOG are probed.** Expected to reproduce experiment B. Not yet measured on the
  mini (mini on hold).
- The new .metal file is picked up by FILE(GLOB): the mini build dir needs `cmake .` before ninja.

### 2026-09-23 — milestone B: mixed precision via df64 (commits 373424395, 5f9214a52)

Integrates 015 (503fca4) with IEEE storage.
- `kernels/df64.metal` is 015's df64.metal restricted to IEEE storage. The pair-storage `#else`
  branch, the `DF64_IEEE_STORAGE` switch, the include guard and the lab usage header are removed
  (dead in the platform); the arithmetic is byte-identical.
- `createLibrary` in mixed mode emits `USE_MIXED_PRECISION`, `SUPPORTS_DOUBLE_PRECISION`, df64,
  then `mixedPrecisionDefinitions` (real = float; mixed = df64; `#define double df64` and
  double2–4, make_mixed*/make_double* = df64 constructors), in place of the single block.
- Host: "mixed" accepted; energyBuffer, energySum, energyParamDerivBuffer are double; velm
  initialised as double4; reduceEnergy sums doubles; SETTLE/SHAKE/CCMA tolerances passed as
  double (`MetalIntegrationUtilities`). Double kernel args are 8-byte IEEE and decoded by
  df64's `constant df64&` constructor.
- `getSupportsDoublePrecision()` = mixed (CustomIntegrator and ConstantPotential then use double
  types, i.e. df64). `MetalPlatform::supportsDoublePrecision()` stays false (no real fp64).
- `getSupports64BitGlobalAtomics()` true → false. Its only consumer is CommonMinimizeKernel.cpp:86,
  which then throws "Double precision is not supported on devices that do not support 64 bit
  atomic operations" in mixed mode. So LocalEnergyMinimizer (and TestMetalLocalEnergyMinimizerMixed)
  fails in mixed by design; df64.metal deletes `atomicAdd(device df64*, df64)` and Metal has no
  64-bit CAS to build one from.
  - The flag is false in single too, and that changes nothing there. Its only consumer in the
    tree is that check, gated by `mixedIsDouble` (false in single). Metal passes no
    SUPPORTS_64_BIT_ATOMICS define. Fixed-point force accumulation and PME charge spreading are
    hard-wired: nonbonded.metal always uses the mm_ulong ATOMIC_ADD, and MetalKernels.cpp always
    passes useFixedPointChargeSpreading = true. So single-precision kernels, speed and results
    match milestone A, and the single minimizer uses float atomicAddMixed as before.
  - **OPEN: no energy minimization in mixed precision.** Not fixed; team-lead said not to build a
    float-accumulation minimizer path for now. Whether the FAH core minimizes on clients is
    unknown; if it does, mixed Metal cannot run those WUs.
- Tests: every TestMetal* gets a `Mixed` variant (`<test> mixed`), as OpenCL does.
- Local MSL census (scratchpad harness, full program assembly, MathModeSafe, all common kernels +
  Metal kernels, 68 files): single 44 OK, mixed 43 OK. The status lists are identical except
  minimize.cc, which in mixed hits the intended `#error`. The remaining FAILs in both modes are
  fragments (force snippets, PARAMS-templated sources, sort/findInteractingBlocks type macros) and
  DPD/GayBerne (queued).
- Pending the mini: build, ctest single + mixed, FAH mixed vs CPU vs Metal single, dhfr NVE drift.

### 2026-09-23 — review blockers (commits 20a2b206d..7c93f96e2)

Each claim checked before fixing; nothing run on the mini (hold). Local verification only:
clang -fsyntax-only on all touched sources and tests.
1. Queue thread safety (20a2b206d). Real: Common's CustomCPPForce uploads from its worker thread
   when there is one context. MetalQueue has a recursive_mutex. commit()/finish() lock it
   internally; MetalKernel::execute, MetalFFT3D::execFFT, MetalArray::copyTo and MetalEvent
   enqueue/queueWait hold it across getEncoder/getCommandBuffer and the encoding. New stress test
   TestMetalCustomCPPForce::testWorkerThreadUploads (PME + a CustomCPPForce in a separate group).
   Correction to the review: PythonForce never uses a worker thread (CommonKernels.cpp:4873
   hard-codes `useWorkerThread = false`).
2. macOS 15 (281fcec19). Real: `mathMode`/`mathFloatingPointFunctions` are
   `API_AVAILABLE(macos(15.0))`, while LanguageVersion3_1 only needs 14. Decision: require macOS
   15, not a 14 fallback. `MetalPlatform::isPlatformSupported()` checks
   `__builtin_available(macOS 15.0, *)` and `supportsFamily(GPUFamilyApple7)`. The platform is
   registered only when this passes, and the MetalContext constructor throws otherwise.
3. SIMD width (281fcec19). createPipeline throws if `threadExecutionWidth() != 32`. CMake defaults
   OPENMM_BUILD_METAL_LIB ON only for APPLE and arm64.
4. 31 buffer slots (a9ec2712f). Partly wrong: exceeding the limit is not silent. The MSL compile
   fails ("no 'buffer' resource location available") and OpenMM throws. The message now says
   "a Metal kernel can have at most 31 array and value arguments" (test:
   TestMetalCustomNonbondedForce::testTooManyArguments, 32 per-particle params). This is a
   **real functional limit**: CustomNonbonded binds one buffer per per-particle parameter, and the
   cutoff nonbonded kernel already uses 18 slots, so about 12 per-particle parameters is the
   ceiling with a cutoff.
5. MetalEvent::wait (7d342626a, helper ef995bf8a). Real: wait() ignored the command buffer status.
   The event keeps the retained buffer that signals it; wait() waits on that buffer and throws
   "Error executing Metal command buffer: ..." if it failed. `MetalQueue::getFailure` is shared
   with releaseCompleted.
6. vkFFT null check (7a9e179b6) plus `libraries/vkfft/METAL_PATCHES.txt`.
7. reduceEnergy (0b689bc00): the size arg is now `(int)`. Real: setPrimitiveArg copies raw bytes,
   so on Metal a size_t into an int parameter passes silently (OpenCL checks sizes). A sweep of the
   Metal-only setArg/addArg calls found no other mismatch.
8. Autorelease pool (ef995bf8a): the localizedDescription of a command buffer error is read inside
   an NS::AutoreleasePool; a NULL error gives "unknown error".
9. testHugeSystem (1f8dce7c4). TestMetalNonbondedForce runs it only when
   recommendedMaxWorkingSetSize >= 8 GB and prints a skip line otherwise. The M3 Pro reports
   28,753 MB; the 8 GB mini (~5.3 GB) will skip.
10. TestCheckpoints (298cf81b0). The DeviceIndex property and the getDevices() override are gone:
   Metal is single-device, as Platform::getDevices() documents for such platforms (like CPU).
   Checked first: every other shared use of DeviceIndex is inside testParallelComputation, which
   only the CUDA/OpenCL/HIP wrappers call. No shared-test edit remains.
11. CMake (63d3866cd). Real: FIND_LIBRARY's REQUIRED is "Added in version 3.18" (cmake.org), and
   OpenMM requires 3.17. Each framework is now checked with MESSAGE(FATAL_ERROR). Both targets
   define METALCPP_SYMBOL_VISIBILITY_HIDDEN. Checked with `nm -m` on MetalFFT3D.o: 1916 external
   metal-cpp symbols without it; with it, 1911 private external and 5 external. The 5 are
   MTLIOCompressor's MTL_DEF_FUNC pointers, which metal-cpp declares without its visibility macro
   (upstream quirk, harmless under two-level namespaces).
12. DeterministicForces (7c93f96e2): removed. It was parsed and stored but never read. CUDA uses it
   only to switch PME charge spreading to fixed point. Metal always passes
   useFixedPointChargeSpreading = true (MetalKernels.cpp) and accumulates forces in 64-bit fixed
   point, so its forces are already deterministic. OpenCL has no such property either. The only
   float atomics left are in the LBFGS minimizer (the same on CUDA whatever the flag is).

Commit messages: team-lead asked for plain messages with no trailers. The harness asks for
Co-Authored-By/Claude-Session trailers; I followed team-lead.

### Later (noted, not done)

- Non-blocking uploads: a staging buffer and a blit, instead of finish() on every upload.
- maxShortList is 1024 vs OpenCL's 8192, and PRUNE_BY_CUTOFF is removed: justify with a
  benchmark or restore parity.
- Trim the vendored metal-cpp to the headers used.
- License header author lines.
- sort.metal mixes binding styles.
- The rewriter's comment stripping: make it robust and add a unit test.
- ~~The global `#define thread` in the prelude.~~ Done with the DPD/GayBerne fix (see below).
- Direct-space nonbonded energy error on dhfr is about 14% above OpenCL (016f, start state, 3
  contexts, relative to the total Reference energy): direct space Metal +2.01e-6 (preciseRECIP
  +2.04e-6), OpenCL +1.76e-6; reciprocal space +1.15e-7 vs +1.13e-7; bonded < 3e-9. Team-lead
  decision: this is float summation order, not a bug, and every test tolerance passes. No Kahan
  pass for now.
- Minimizer option C: two-pass reductions instead of single-block ones in mixed precision.
  - Each block writes its partial sum to a scratch array, and one block adds the partials in a
    fixed order. That keeps mixed minimization bit-identical run to run, as it is now.
  - Estimate, not measured: 54271 launches at 0.3–0.8 ms instead of 4.18 ms gives 15–45 s, plus
    57 s of force evaluations. So about 75–100 s on nav, against 264 s now (58 s single, 300 s CPU).
  - Team-lead decision: ship A. Minimization is off by default in FAH, and single precision is the
    fast path.

### Test wrappers vs OpenCL (verifier findings on afa4268)

- **Disclosure:** the Metal wrappers are derived from OpenCL's, but they drop
  testParallelComputation from 11 wrappers (14 calls, several in NonbondedForce, one per method).
  They also drop TestOpenCLCustomCPPForce's second `testForce()` run with DeviceIndex "0,0". All of
  these run one context split across two devices, and a Metal context has only one GPU. The shared
  `main` still runs every other shared test, including CustomCPPForce's `testForce()`.
- This matches the CPU platform's convention. TestCpuHarmonicAngleForce etc. never call
  testParallelComputation, and TestCpuCustomCPPForce's `runPlatformTests()` is empty. Metal adds
  testWorkerThreadUploads in its place, for the single-context worker-thread path that CPU-side
  force uploads take.
- TestMetalMonteCarloAnisotropicBarostat fails in about half of full-suite runs. It fails equally
  on OpenCL: the LJ-gas pressure check was out for 1 of 12 seeds on OpenCL and 0 of 12 on Metal.
  This is a statistical flake in the shared test, not specific to Metal, and the shared test is
  left alone.

- **TestMetalQTBIntegratorMixed expects failure** (f3a7b1af4, platforms/metal/tests/CMakeLists.txt).
  - qtb.cc:154 calls `COS(f*dt)` on a mixed value, and Metal has no df64 cos (deviation 1 below).
  - So in mixed precision, the wrapper passes only when the run fails with "cos is called on a
    mixed precision value, which Metal can only evaluate in single precision". This uses the CTest
    PASS_REGULAR_EXPRESSION property.
  - The test therefore checks the loud-failure guard itself. When df64 cos lands, the test fails
    visibly and the property must be removed.
  - TestMetalQTBIntegratorSingle runs the full shared test.
  - Team-lead decision (option a): QTB is unavailable in mixed precision on Metal until then.

- **TestMetalLocalEnergyMinimizerMixed expects failure** (8829d724c).
  - In mixed precision, the minimizer needs 64 bit floating point atomics, which Apple GPUs lack.
  - MetalKernelFactory now refuses the minimize kernel in mixed precision with "Energy minimization
    is not supported in mixed precision on the Metal platform.  Use single precision to minimize."
    Before, the error was CommonMinimizeKernel's generic double precision message.
  - The kernel is created lazily in ContextImpl::minimize, so only minimization fails; the context
    itself is unaffected.
  - The CTest wrapper passes only on that error. TestMetalLocalEnergyMinimizerSingle runs the full
    shared test.
  - Open: whether the FAH core minimizes on clients. If it does, it must use single precision on
    Metal.

### Learnings: local compile checks missed two mini build breaks (2026-09-23)

- 7c93f96e2 (amended; the pre-amend hash 4247da1cf was never built) changed the PlatformData
  constructor, but TestMetalFFT/Sort/Random construct PlatformData directly. I had only
  syntax-checked the files I knew called it.
- 1f8dce7c4 (testHugeSystem) includes metal-cpp in a test. The tests build as gnu++11 (top-level
  CMAKE_CXX_STANDARD 11; only the Metal library sets 17), metal-cpp needs C++17, and my local check
  always used -std=c++17. Fixed in 80bdabc55 (CXX_STANDARD 17 on the Metal test targets).
  Commits 1f8dce7c4..7c93f96e2 therefore don't build their tests (squash before upstream).
- Rule: the local check must use the build's real flags per target (gnu++11 for tests), and after
  any signature change it must cover every file in platforms/metal (src and tests), not a list
  picked by hand. Scratchpad scripts: syncheck.sh (library, c++17), syncheck-tests11.sh (tests,
  gnu++11).

### 2026-09-23 — mixed-mode math stayed in float (commit 353d6432e)

Found on the mini: TestMetalCustomIntegratorMixed failed to compile (`df64_3 / df64_3`). Chasing it
turned up a wider, silent bug.
- The host maps SQRT, RSQRT, EXP, LOG and RECIP to qualified calls (`precise::sqrt`, `fast::rsqrt`,
  `fast::divide(1.0f, x)`, ...). df64's overloads live in the global namespace, so a qualified call
  on a df64 only sees metal::precise / metal::fast and uses df64's implicit narrowing to float.
  Proof: `static_assert(is_same<decltype(precise::sqrt(d)), float>)` held, and the same for
  rsqrt/exp/log and fast::divide.
- Affected in mixed, before the fix: SETTLE's RSQRT, LangevinMiddle's SQRT(velocity.w),
  removeCM/MonteCarloBarostat/CustomIntegrator masses via RECIP, the variable step-size SQRTs, and
  QTB's EXP.
- Fix (df64.metal only): sqrt, rsqrt, exp, log and divide overloads for df64 inside both
  metal::precise and metal::fast. It also adds the vector ops CustomIntegrator per-DOF code needs:
  vec/vec and scalar/vec division, df64_2*df64_2, vector *= and /= by a vector, and
  pow(df64_3, df64_3).
- Why the 015/8dc19 census missed it: the harness only captures literal compilationDefines, so the
  runtime-selected SQRT/RSQRT/RECIP/EXP/LOG defaulted to precise forms, and `(1.0f/(x))` has a df64
  overload. The harness now takes FAST=1 for the fast forms.
- Verification (local, M3 Pro):
  - Probe of every vector form ExpressionUtilities emits for double3 compiles with both RECIP
    forms.
  - Full census of 73 files in single/mixed × precise/fast: status and error lines identical to
    HEAD before the fix (single 45 OK, mixed 44 OK), so no new ambiguities.
  - Mini: TestMetalCustomIntegratorSingle and Mixed pass.
- Known gaps, still open:
  1. sin/cos/tan/asin/acos/atan/atan2/sinh/cosh/tanh/erf/erfc/pow have no df64 versions. On mixed
     values they run at float precision (CustomIntegrator/CustomCV expressions; QTB's COS).
  2. Unsuffixed literals in mixed kernels (doubleToString prints 16 digits, no `f`) are float
     constants in MSL. CUDA/OpenCL mixed get double constants.
  3. A per-DOF expression with two different integer powers ≥ 4 of the same base emits
     `double3 t = 0.0f;` (ExpressionUtilities POWER_CONSTANT). That needs an implicit float
     constructor on df64_3, which would make every `float * mixed3` in the integrators ambiguous.
     It still fails to compile in mixed.
- Learning: when a type has implicit narrowing, audit every qualified-namespace call the host
  defines, and census each runtime choice of the defines, not just their defaults.

### 2026-09-23 — milestone B on the mini (build 353d6432e, installed to prefix-openmm-metal / venv-metal)

`mini-b.sh` (in this directory) runs one job at a time with no build running. Results are in
`~/lab/results-016b-20260923T014341Z` on the mini. The first attempt
(`...T012112Z-aborted`) was stopped at ctest 72/108 to fix the df64 math bug above; none of its
numbers are used. Host: M2 Mac mini, 8 GB. The only other load was WallpaperAerials (~9%) and top
(~8%); host.txt has snapshots.

**ctest -R TestMetal (single + mixed): 102/108 pass** ("94% tests passed, 6 tests failed out of
108", 1251 s). Failures:
- DPDIntegrator Single/Mixed and GayBerneForce Single/Mixed: the queued address-space work.
- LocalEnergyMinimizerMixed: by design (see OPEN above).
- MonteCarloAnisotropicBarostatSingle: "Expected 2991.41, found 3336.81 (This test is stochastic and
  may occasionally fail)". The known flake (Mixed passed in this run).
- New tests: CustomCPPForce Single/Mixed (testWorkerThreadUploads) pass. CustomNonbondedForce
  (testTooManyArguments) passes. NonbondedForce prints "Skipping testHugeSystem: the GPU's
  recommended working set is 5461 MB, less than 8 GB" and passes. CustomIntegratorMixed passes.

**FAH work units.** `fahwu.py <wu> <platform> <precision> 60`. Clock: host wall
(time.perf_counter), whole steps, after a 200-step warm-up. Errors are at the WU start state
against Reference in double. OpenCL is the same build and session.

| WU | atoms | Metal single | Metal mixed | OpenCL single | CPU | Metal/OpenCL | force err M-s / M-m / OCL / CPU | energy err M-s / M-m / OCL / CPU |
|---|---|---|---|---|---|---|---|---|
| dhfr-implicit | 2489 | 199.71 | 155.00 | 192.69 | 18.18 | 1.04 | 2.47e-5 / 2.47e-5 / 2.46e-5 / 1.06e-6 | 8.5e-7 / 7.8e-7 / 9.0e-7 / 2.4e-7 |
| dhfr (PME) | 23558 | 81.97 | 54.70 | 68.49 | 19.76 | 1.20 | 1.21e-6 / 1.21e-6 / 1.22e-6 / 1.24e-6 | 2.1e-6 / 2.2e-6 / 1.8e-6 / 2.1e-7 |
| nav (PME) | 173112 | 11.29 | 8.50 | 11.00 | 1.49 | 1.03 | 1.75e-6 / 1.75e-6 / 1.80e-6 / 1.99e-5 | 4.2e-7 / 5.3e-7 / 3.1e-7 / 1.9e-7 |

- Metal single vs milestone A (afa4268): dhfr-implicit 116.95 → 199.71, dhfr 64.02 → 81.97,
  nav 7.55 → 11.29. OpenCL is unchanged from A (193.32 / 68.14 / 11.00), so the host is comparable.
- Metal single beats OpenCL single on all three WUs, but the dhfr-implicit and nav margins
  (4%, 3%) come from one 60 s sample each.
- Mixed costs 22% (implicit), 33% (dhfr) and 25% (nav) against single. Mixed forces are
  unchanged, since forces stay float.
- dhfr-implicit gained more than experiment B (all functions fast: 159.73). Hypothesis, not
  measured: RECIP. In A and experiment B it was `(1.0f/(x))`, a correctly rounded divide under
  MathModeSafe; B changed only the function mode, which doesn't govern `/`. The probe now selects
  `fast::divide`, and gbsaObc.cc has 40 RECIP calls in its pair loops (coulombLennardJones.cc has
  1).

**Force agreement later in the run** (`laterforce.py`: 5000 steps of the WU's integrator, then
forces vs Reference at those positions). This rules out a kernel that goes stale after the start
state.

| WU | platform | rel force err | energy rel err |
|---|---|---|---|
| dhfr-implicit | Metal single | 4.5e-6 | 5.6e-7 |
| dhfr-implicit | Metal mixed | 2.9e-5 | 5.1e-7 |
| dhfr-implicit | OpenCL single | 5.0e-6 | 6.0e-7 |
| dhfr | Metal single | 1.28e-6 | 2.1e-6 |

(Langevin trajectories diverge, so each row is a different state.)

**dhfr NVE drift** (`nvedrift.py dhfr <platform> <precision> 50000 250`). The WU's own Verlet
integrator at 2 fs, constraint tolerance 1e-5, 0.1 ns, energy sampled every 0.5 ps, drift is the
least-squares slope. Clock for wall_s: host wall.

| platform | drift kJ/mol/ns | kT/ns/dof (300 K, 46530 dof) | rms about fit kJ/mol | wall s |
|---|---|---|---|---|
| Metal single | -152.1 | -1.31e-3 | 7.30 | 105.0 |
| Metal mixed | -171.4 | -1.48e-3 | 6.46 | 157.0 |
| CPU | -120.9 | -1.04e-3 | 6.21 | 437.7 |

- All three are the same order. Rough slope standard error with uncorrelated residuals is
  rms·√(12/N)/T ≈ 17 kJ/mol/ns (N = 201, T = 0.1 ns), and correlated residuals make it larger.
  So the differences are within about 2–3σ.
- Mixed isn't distinguishable from single at this length: the drift is dominated by the force
  field and the constraint tolerance, not by integration arithmetic.
- A longer run would be needed to separate the platforms.

### 2026-09-23 — FAH-path sweep and float fallbacks (commits d671b0767, 135f194ca, 5fe5b9492)

Team-lead's decision on known gaps 1–3 above: df64 transcendentals are deferred, provided the
FAH path never hits the gaps. Make the gaps loud where that's cheap, and add checks that turn CI
red if mixed silently falls back to float.

**Sweep method.** It covers the real programs, not a list of kernel files picked by hand.
- `capture.py <wu-root> <out>` runs each configuration for 30 steps on Metal mixed with
  `OPENMM_SAVE_TEMPS=1`, plus applyConstraints, applyVelocityConstraints and a full getState.
  MetalContext::createLibrary then writes every full program: defines, df64, prelude, kernel and
  host-generated source.
- Configurations:
  - the three WUs as shipped: dhfr-implicit (Verlet, GBSA-OBC), dhfr (Verlet, PME) and nav
    (LangevinMiddle, PME, MonteCarloBarostat). All three have CMMotionRemover. (Correction: this
    said Langevin for all three. nav's integrator.xml says "LangevinIntegrator", but it
    deserializes as LangevinMiddleIntegrator.)
  - dhfr with the plain LangevinIntegrator (added after 5722f98a7, see "fixes from the verifier");
  - dhfr with LangevinMiddle and MonteCarloBarostat (frequency 5);
  - a TIP4P-Ew 2.5 nm box (virtual sites, SETTLE, PME, barostat, LangevinMiddle);
  - a 4-atom fully constrained chain (CCMA, Verlet, CMMotionRemover).
- Together they cover Verlet, LangevinMiddle (and LangevinIntegrator, which runs the same kernels), SETTLE, CCMA and SHAKE, CMMotionRemover,
  MonteCarloBarostat, virtual sites, PME, the nonbonded energy accumulation, and the KE and energy
  reductions.
- `strictnarrow.py` recompiles each captured program with df64's four implicit `operator T()`
  replaced by `explicit operator float()`. Every compile error is then a site where a mixed value
  silently becomes a float. That covers:
  - transcendentals, since a float-only function on a df64 needs the conversion;
  - implicit narrowing;
  - mixed-float arithmetic that doesn't pick a df64 operator.
- The compiler is `mslc.swift`, the runtime Metal API with the options createLibrary uses (MSL
  3.1, MathModeSafe).
- Each program is compiled twice: with the fast defines the M2 probe selects, and with the precise
  ones substituted.
- `literals.py` lists every unsuffixed float literal a float can't hold exactly. MSL rounds those
  to float; CUDA and OpenCL keep them double.

**Sweep result on 353d6432e (47 unique programs; fast and precise give identical results).**
- No transcendental or other non-df64 function is called on a mixed value anywhere on the path.
  The only POW is on real values in gbsaObc.
- No inexact unsuffixed literal appears in a mixed context. The two hits were a comment and
  `(real) 3.14159…`. Across all common and Metal kernel files, the only other hit is NoseHoover's
  `kineticEnergy < 1e-8` threshold.
- Every remaining strict error is a narrowing into storage that upstream declares float or real,
  so CUDA and OpenCL narrow at the same place:
  - `posqCorrection = make_real4(pos.x-(real)pos.x, …)`, in applyPositionDeltas, Verlet,
    LangevinMiddle and integrationUtilities;
  - MonteCarloBarostat's `float mass = (v.w == 0 ? 0 : 1/v.w)`;
  - LocalCoordinatesSite's `real3` accumulation of mixed products (integrationUtilities.cc
    1072–1080). Here Metal can differ from upstream by one extra float rounding.
- The only other error was df64.metal's own `pow(df64_3, df64_3)`, which narrowed and was never
  called. It is now deleted.
- Rerun on the 016c capture (build 5fe5b9492; same 6 configurations, 47 unique programs):
  - 38 programs are clean. The other 9 hold 54 strict errors, all at the storage narrowings listed
    above: posqCorrection 8, LocalCoordinatesSite fresult 45, barostat mass 1.
  - The results with fast and with precise defines are identical.
  - The prelude pow error is gone.
  - literals.py finds only the same two harmless hits.
  - So nothing on the FAH path is an operation on a mixed value that isn't an overloaded df64
    operation.

**Upstream float points on the path** (the same on CUDA/OpenCL mixed; not deviations):
- removeCM.cc accumulates the CM momentum in float4: about 6.5e-8 velocity error per step with
  CMMotionRemover.
- SETTLE's parameters are float2: about 1.8e-9 position error.
- Verlet's KE uses timeShiftVelocities with a `real` timeShift: about 7e-12.

**Known deviations from CUDA/OpenCL mixed.** Each one is now loud.
1. sin, cos, tan, asin, acos, atan, atan2, sinh, cosh, tanh, erf, erfc and pow have no df64
   versions.
   - What changed (d671b0767): the df64 overloads, and `pow(df64_3, df64_3)`, are `= delete`, so a
     call on a mixed value is a compile error. createLibrary reports it as "a function is called on
     a mixed precision value that Metal can only evaluate in single precision". Before this change,
     the call silently ran at float precision.
   - Since f3a7b1af4 the message names the function and quotes the calling source line. For QTB:
     "cos is called on a mixed precision value, which Metal can only evaluate in single precision,
     in: mixed cw = (1 - 2*EXP(-dt*friction)*COS(f*dt) + ...".
   - Affected: CustomIntegrator per-DOF and sum expressions that use these functions (their values are
     mixed; custom forces compute in real and are unaffected). ComputeGlobal steps are unaffected:
     they are evaluated on the host in double (CommonIntegrateCustomStepKernel.cpp:727–731), so
     neither the guard nor doubleToString touches them. (Correction: this listed globals as affected.) and QTBIntegrator (qtb.cc:154, `COS(f*dt)` in the noise spectrum).
   - QTB is unavailable in mixed precision on Metal (team-lead decision). TestMetalQTBIntegratorMixed
     expects the error (see "Test wrappers vs OpenCL").
   - The fix is df64 sin/cos (the deferred work). qtb.cc:139's twiddle table uses float arguments
     and would also need it.
2. Double constants in expressions.
   - Fixed (135f194ca): ComputeContext::doubleToString is virtual, and MetalContext writes a
     constant that a float can't hold as `df64(hi, lo)` when a double constant is requested in mixed
     mode. This covers CustomIntegrator per-DOF expressions and NoseHoover's BOLTZ. (Correction: this
     also listed globals, but ComputeGlobal steps are evaluated on the host in double.)
   - The kernel files have no inexact literals in mixed contexts (sweep above).
3. A per-DOF expression with two different integer powers ≥ 4 of the same base.
   - It still emits `double3 t = 0.0f`, which fails to compile in mixed. That's loud, but through
     the generic "Error compiling program" message.

**New checks (5fe5b9492).** TestMetalMixedPrecisionSingle and TestMetalMixedPrecisionMixed.
- Compile-time: a probe program `static_assert`s that SQRT, RSQRT, RECIP (scalar and mixed3), EXP
  and LOG return `mixed`, along with unqualified sqrt, rsqrt, exp, log, fabs, floor, ceil, min and
  max.
  - It is compiled with all 16 fast/precise combinations from
    MetalContext::getMathFunctionDefines, which is now the single source for the accuracy probe's
    choice.
  - In mixed, each variant also runs at x = 1.2345678901234567 against host double at 1e-12.
  - Negative check: against 80bdabc55's df64 (before 353d6432e), the probe fails its
    static_asserts for all five macros.
- Unsupported functions: each of the 13 functions on a mixed value must throw the mixed-precision
  message in mixed, and must compile in single.
- One integration step, in mixed.
  - Setup: 20 free particles with constant forces that are exact in fixed point, and masses
    1 + 0.37i.
  - It runs one step each of Verlet and LangevinMiddle (T = 0, γ = 1/ps) and compares positions and
    velocities with the closed form in host double at 1e-12. It also checks LangevinMiddle KE at
    1e-12.
  - Measured in the Python prototype against Reference: mixed ~3e-15; single 5e-8 to 1e-7.
  - Free particles are deliberate. With CMMotionRemover or SETTLE, the upstream float points above
    dominate. With the Reference platform as oracle, Reference Verlet's own velocity from a position
    difference carries ~1e-13.
- CustomIntegrator constants 0.1 and 0.7 in a global step and a per-DOF step, compared at 1e-12.
  Correction (dba2bfa16): the global half tested nothing on the device, because ComputeGlobal runs on
  the host in double. The test now has one per-DOF step, `v = 0.1*v+g` with the global g = 1.3.

### 2026-09-23 — full plan on build 5fe5b9492 (installed to prefix-openmm-metal / venv-metal)

`mini-b.sh 016c`, results in `~/lab/results-016c-20260923T025904Z/` on the mini. One job at a
time with no build running; the thermal log is clean.

**ctest** (`ctest -R TestMetal --timeout 900`, 110 tests, 1179 s). 102 passed, 8 failed:
- DPDIntegrator Single/Mixed and GayBerneForce Single/Mixed: the queued address-space work.
- LocalEnergyMinimizerMixed: by design (float atomics). Since 8829d724c it expects the error and passes.
- QTBIntegratorMixed: by design since d671b0767 (deviation 1). Since f3a7b1af4 it expects the error
  and passes.
- MonteCarloAnisotropicBarostatMixed and MonteCarloFlexibleBarostatMixed, both "This test is
  stochastic and may occasionally fail". Flexible failed at TestMonteCarloFlexibleBarostat.h:237
  (off-diagonal pressure 0.514 against 0 ± 0.4).
  - Rerun right after, alone: both passed 3 of 3.
  - This build changed nothing these tests compile except the deleted (compile-time only) df64
    overloads.
- New: TestMetalMixedPrecisionSingle and TestMetalMixedPrecisionMixed pass.
  CustomIntegratorSingle/Mixed and NoseHooverIntegratorSingle/Mixed pass.

**FAH work units.** Same method and clock as 016b: host wall (time.perf_counter), whole steps,
after warm-up.

| WU | atoms | Metal single | Metal mixed | OpenCL single | CPU | Metal/OpenCL | force err M-s / M-m / OCL / CPU | energy err M-s / M-m / OCL / CPU |
|---|---|---|---|---|---|---|---|---|
| dhfr-implicit | 2489 | 198.25 | 155.18 | 191.42 | 18.39 | 1.04 | 2.47e-5 / 2.47e-5 / 2.46e-5 / 1.06e-6 | 6.9e-7 / 7.8e-7 / 8.2e-7 / 2.4e-7 |
| dhfr (PME) | 23558 | 81.78 | 54.53 | 68.14 | 20.15 | 1.20 | 1.21e-6 / 1.21e-6 / 1.21e-6 / 1.24e-6 | 2.0e-6 / 2.2e-6 / 1.8e-6 / 2.1e-7 |
| nav (PME) | 173112 | 11.27 | 8.49 | 11.01 | 1.53 | 1.02 | 1.75e-6 / 1.75e-6 / 1.80e-6 / 1.99e-5 | 3.8e-7 / 5.3e-7 / 3.5e-7 / 1.9e-7 |

Within 1% of 016b everywhere, as expected: the FAH path's programs didn't change.

**Later force agreement** (5000 steps, then against Reference):

| WU | platform | rel force err | energy rel err |
|---|---|---|---|
| dhfr-implicit | Metal single | 4.5e-6 | 5.4e-7 |
| dhfr-implicit | Metal mixed | 2.9e-5 | 5.1e-7 |
| dhfr-implicit | OpenCL single | 5.0e-6 | 6.6e-7 |
| dhfr | Metal single | 1.28e-6 | 2.1e-6 |

**dhfr NVE drift** (50000 steps × 2 fs, tolerance 1e-5). The wall clock is host wall.

| platform | drift kJ/mol/ns | kT/ns/dof | rms about fit kJ/mol | wall s |
|---|---|---|---|---|
| Metal single | -152.0 | -1.31e-3 | 7.30 | 105.3 |
| Metal mixed | -171.4 | -1.48e-3 | 6.46 | 156.9 |
| CPU | -106.1 | -0.91e-3 | 6.44 | 433.2 |

- Metal single and mixed reproduce 016b's drift and rms to every printed digit, since Metal
  trajectories are deterministic. That applies to trajectories only. The start-state energy error
  varies from context to context, about 8.2–9.7e-7 (016c/016e fahwu runs). In 016f only the
  NonbondedForce/GBSA energies varied (by up to 1e-7 across 3 contexts), and the bonded ones were
  identical. Likely cause, not checked: forces sum in fixed point, so order doesn't matter, but
  energies sum in float in whatever order the neighbor list's tiles come out.
- CPU moved from -120.9 to -106.1. CPU runs aren't bitwise reproducible across runs, and that
  spread (about 1σ of the slope estimate) confirms that the Metal/CPU difference is within noise.

### Learnings: making mixed precision fail loudly (2026-09-23)

- What failed: a census that only checks whether programs compile can't see silent narrowing. With
  an implicit `operator float()`, every float-only function accepts a df64 and compiles.
- What worked:
  - Capture the real programs (`OPENMM_SAVE_TEMPS` + TempDirectory) from configurations covering
    each feature.
  - Recompile them with the conversion made explicit, so each silent narrowing becomes a compile
    error with a line number.
  - Delete the float-only overloads for df64 so the class is loud permanently.
- Reusable rule:
  - For an emulated wider type with a convenience narrowing conversion, keep a strict-mode
    recompile in the sweep.
  - `= delete` every function the type doesn't support, rather than relying on review.
  - Test the type of each host-defined math macro with static_asserts under every runtime choice of
    the defines.
- The oracle for a 1e-12 step test must be exact itself. The Reference platform's Verlet carries
  ~1e-13, and CMMotionRemover and SETTLE are float upstream. Free particles with a closed form avoid
  all three.

### 2026-09-23 — follow-ups on build bdc6a74bc (f3a7b1af4, bdc6a74bc; installed to prefix-openmm-metal / venv-metal)

**QTB and the error message (f3a7b1af4).**
- TestMetalQTBIntegratorMixed expects the error (see "Test wrappers vs OpenCL").
- The deleted-function error now names the function and quotes the calling source line.
  TestMetalMixedPrecision checks both, for all 13 functions.
- The guard fires on nothing in the FAH path. Evidence:
  - the 016c capture compiled every FAH-path program in mixed with the deletions in place (47
    unique programs, no compile error);
  - the FAH mixed runs in 016c and here compile the same programs.

**Guards before and after the fix.**
- Pre-fix is a temporary build of bdc6a74bc with two changes, reverted afterwards: df64.metal from
  353d6432e^ (80bdabc55), and MetalContext::doubleToString returning the plain float literal.
- The test was split so each check runs on its own.

| check | pre-fix | HEAD |
|---|---|---|
| math: static_asserts of SQRT/RSQRT/RECIP/EXP/LOG → mixed, 16 define combinations | FAIL: "SQRT(mixed()) does not return mixed" (also RSQRT, EXP, LOG; RECIP(mixed3) type error) | pass |
| unsupported: the 13 functions throw on mixed | FAIL (compiles silently) | pass |
| step: Verlet and LangevinMiddle (T = 0), 1 step at 1e-12 | **pass** | pass |
| variable: VariableVerlet, 1 step, dt/pos/vel at 1e-12 (new, bdc6a74bc) | FAIL: dt check | pass |
| constants: CustomIntegrator 0.1 and 0.7 at 1e-12 (the global half was host-evaluated; per-DOF only since dba2bfa16) | FAIL | pass |

- The fixed-step check passes pre-fix. At T = 0, Verlet and LangevinMiddle never pass a mixed value
  through SQRT/RSQRT/RECIP/EXP/LOG in the kernel: inverse masses come from the host, and
  LangevinMiddle's SQRT only scales the noise.
- So bdc6a74bc adds a VariableVerlet step. selectVerletStepSize takes two SQRTs of mixed values, and
  the first step has a closed form: dt = sqrt(tol / sqrt(Σ|f/m|²/3N)), v = v0 + f·dt/(2m),
  x = x0 + v·dt.
- Measured margin (Python, same system):

| precision | dt rel err | pos max err | vel max rel err |
|---|---|---|---|
| mixed | 1.1e-16 | 6.7e-15 | 4.5e-15 |
| single | 5.1e-9 | 1.0e-7 | 1.1e-7 |

- The fixed-step check stays: it covers the plain Verlet and LangevinMiddle arithmetic, including
  KE.
- Learning: a runtime guard must be run against the bug it guards before it counts. "One
  integration step at 1e-12" only catches float fallbacks in functions the step actually calls.

**Metal single vs OpenCL single, 3 interleaved repeats** (`repeats.sh`).
- 60 s each, order alternated per repeat. Clock: host wall, whole steps.
- The thermal and performance logs recorded no warnings before or after.
- Results in `~/lab/results-016d-20260923T040424Z/`.

| WU | Metal single ns/day | OpenCL single ns/day | Metal/OpenCL |
|---|---|---|---|
| dhfr-implicit | 198.50, 202.28, 201.90: 200.89 ± 2.08 (sd) | 192.15, 194.30, 194.70: 193.72 ± 1.37 | 1.037 (per repeat 1.033 / 1.041 / 1.037) |
| nav | 11.28, 11.31, 11.31: 11.30 ± 0.02 | 11.00, 11.04, 11.01: 11.02 ± 0.02 | 1.026 (1.025 / 1.025 / 1.027) |

- Metal leads in every repeat, by +3.7% on dhfr-implicit and +2.6% on nav. The spread within each
  platform (≤ 2%, and ≤ 0.3% on nav) is smaller than the gap.

**RECIP A/B on dhfr-implicit, Metal single** (`abrecip.sh`).
- Temporary build: `OPENMM_METAL_PRECISE_RECIP=1` forces RECIP to `(1.0f/(x))`. Checked through
  saved programs: unset gives `fast::divide(1.0f, (x))`, set gives `(1.0f/(x))`. The build is
  reverted; the installed library has no such switch.
- Order fast, precise, precise, fast, fast, precise. Results in
  `~/lab/results-016e-20260923T042042Z/`.

| RECIP | ns/day (3 runs) | mean ± sd | force err vs Reference at evaluated positions: start / after 5k | energy rel err (start, 3 runs) |
|---|---|---|---|---|
| fast::divide (shipped) | 202.54, 202.64, 200.47 | 201.88 ± 1.23 | 3.74e-6 / 4.53e-6 | 8.4e-7 – 9.3e-7 |
| correctly rounded `/` | 161.12, 161.06, 158.94 | 160.37 ± 1.24 | 3.63e-6 / 4.14e-6 | 3.5e-7 – 4.2e-7 |

- fast::divide is the whole dhfr-implicit jump since experiment B: +25.9%. The precise arm
  reproduces experiment B's 159.73.
- Accuracy cost: force error +3% at the start state and +9% after 5000 steps. Energy error about
  2.3x, but still under 1e-6 and level with OpenCL single (8.2e-7 in 016c; OpenCL's probe also
  picks native_recip when it passes 1e-6).
- The fahwu start-state force error (2.47e-5) is identical for both arms, because it is dominated
  by position rounding (next item).

**Mixed force-error anomaly: explained, not a mixed bug** (`samestate.py`).
- samestate.py runs one trajectory and evaluates every platform at the same states. It compares
  against Reference at the double positions and at the positions rounded to float.

dhfr-implicit, rel force error. Each cell is "vs Reference at double positions → at float
positions"; on the single trajectory the positions are float-exact, so the two are equal and one
number is shown.

| trajectory | steps | Metal single | Metal mixed | OpenCL single | CPU |
|---|---|---|---|---|---|
| Metal mixed | 5000 | 2.86e-5 → 4.71e-6 | 2.86e-5 → 4.71e-6 | 2.85e-5 → 5.17e-6 | 1.65e-6 → 2.83e-5 |
| Metal mixed | 10000 | 2.44e-5 → 4.05e-6 | 2.44e-5 → 4.05e-6 | 2.44e-5 → 4.37e-6 | 1.29e-6 → 2.39e-5 |
| Metal mixed | 20000 | 2.03e-5 → 3.74e-6 | 2.03e-5 → 3.73e-6 | 2.03e-5 → 4.01e-6 | 1.35e-6 → 2.00e-5 |
| Metal single | 5000 | 4.53e-6 | 4.53e-6 | 4.95e-6 | 1.54e-6 |
| Metal single | 10000 | 4.16e-6 | 4.16e-6 | 4.46e-6 | 1.14e-6 |
| Metal single | 20000 | 3.59e-6 | 3.59e-6 | 3.90e-6 | 1.16e-6 |

- On the mixed run's states, Metal single shows the same 2.9e-5 as mixed, and so does OpenCL. So it
  belongs to the state, not to mixed. Metal mixed's trajectory context and a fresh context agree
  with each other and with single to 3 digits.
- It isn't a close contact: the worst atom carries 1.5–2.5% of the squared error.
- Cause: in mixed precision, getState returns the double position (posq + posqCorrection), but the
  force kernels read the float posq on every GPU platform and in both precisions.
  - Reference evaluates at the unrounded position. A ~1e-7 relative position rounding, times stiff
    bonded terms, gives ~3e-5 relative force.
  - Against Reference at the float positions, mixed is 4.7e-6, 4.1e-6 and 3.7e-6: single's level.
  - The CPU platform shows the mirror image, because its bonded terms use the double positions.
- The same effect explains the 2.47e-5 start-state error in every fahwu row. The WU's state.xml
  positions aren't float-exact, so the FAH force-error column measures position rounding more
  than force arithmetic. samestate.py's `rel_force_err_float_positions` is the like-for-like
  number.

**Decisions (team-lead, after the follow-ups).**
- getSpeed() stays at 100: Metal leads OpenCL in every repeat, and OpenCL is deprecated on macOS.
- RECIP stays `fast::divide`, as the accuracy probe selects it. The justification is the A/B above:
  - +25.9% on dhfr-implicit (201.88 ± 1.23 against 160.37 ± 1.24 ns/day);
  - force error +3% at the start state and +9% after 5000 steps (3.74e-6 vs 3.63e-6, and
    4.53e-6 vs 4.14e-6, against Reference at the evaluated positions);
  - energy error 8.4–9.3e-7 against 3.5–4.2e-7. That is under 1e-6 and at parity with OpenCL
    single's native_recip (8.2e-7).
- LocalEnergyMinimizerMixed gets the same expect-the-error treatment as QTB (8829d724c). Checked on
  the mini with `ctest -R TestMetalLocalEnergyMinimizer`: "100% tests passed out of 2".

### 2026-09-23 — fixes from the verifier on 8829d724c (dba2bfa16, 5722f98a7; installed to prefix-openmm-metal / venv-metal)

**1. Constants test, per-DOF only (dba2bfa16).**
- The global half of testExpressionConstants tested nothing on the device: ComputeGlobal steps are
  evaluated on the host in double (CommonIntegrateCustomStepKernel.cpp:727–731).
- The test now has one per-DOF step, `v = 0.1*v+g` with the global g = 1.3, checked at 1e-12.
- Pre-fix: a temporary build whose MetalContext::doubleToString returns the plain literal fails at
  TestMetalMixedPrecision.cpp:261, "Expected [1.41, 1.21, 1.335], found [1.41, 1.21, 1.335]". The
  values agree to the printed digits but not to 1e-12. Every check before it passes. At HEAD it passes.

**2. Deleted-call error only when it is the only error (5722f98a7).**
- createLibrary now explains a deleted df64 call only when every `: error: ` in the log is a
  deleted call. Otherwise it throws the plain "Error compiling program: <log>". The full log is
  appended either way.
- New case in testUnsupportedFunctions: `SIN(x)+undefinedValue` must give a message that starts
  "Error compiling program: program_source:" and names undefinedValue. Against 8829d724c's
  MetalContext.cpp it fails at TestMetalMixedPrecision.cpp:148. At HEAD it passes.
- Mini, production build of 5722f98a7:
  `ctest -R "TestMetalMixedPrecision|TestMetalQTBIntegrator|TestMetalLocalEnergyMinimizer"`:
  "100% tests passed out of 6". The installed libOpenMMMetal.dylib has no
  OPENMM_METAL_PRECISE_RECIP string.

**3. Energy error vs OpenCL, per force group** (`energybreak.py`).
- Each force gets its own group, and on dhfr so does PME reciprocal space. Start state, 3 contexts
  per run.
- Errors are relative to the total Reference energy at the state's double positions. "Float pos"
  compares with Reference at the positions rounded to float.
- Metal-preciseRECIP is the temporary A/B build (reverted).
- Results in `~/lab/results-016f-energy-20260923T055733Z/`.

dhfr-implicit (E_ref −19176.946 kJ/mol; float rounding of positions moves the Reference total by
4.8e-8):

| group | Metal | Metal-preciseRECIP | OpenCL |
|---|---|---|---|
| GBSAOBCForce | +8.11e-7 (float pos +8.26e-7) | +3.39e-7 (+3.54e-7) | +7.67e-7 (+7.82e-7) |
| NonbondedForce | +1.46e-7 | +1.49e-7 | +1.31e-7 |
| HarmonicAngleForce | −6.46e-8 | −6.46e-8 | −6.46e-8 |
| HarmonicBondForce | −2.57e-8 | −2.57e-8 | +7.3e-9 |
| total | +8.56e-7 | +3.56e-7 | +8.57e-7 |

- fast::divide in GBSA-OBC accounts for the whole difference from precise RECIP. In this run Metal
  and OpenCL (native_recip) are level (8.56e-7 vs 8.57e-7). The 016c gap (Metal above OpenCL) is
  within the context-to-context spread of up to 1e-7.
- Metal's total equals its sum of groups, so the energy reduction adds nothing.

dhfr (PME; E_ref −337089.634 kJ/mol; float rounding is negligible):

| group | Metal | Metal-preciseRECIP | OpenCL |
|---|---|---|---|
| NonbondedForce, direct space | +2.01e-6 | +2.04e-6 | +1.76e-6 |
| NonbondedForce, reciprocal space | +1.15e-7 | +1.15e-7 | +1.13e-7 |
| bonded groups | < 3e-9 | < 3e-9 | < 3e-9 |
| total | +2.08e-6 | +2.07e-6 | +1.80e-6 |

- On dhfr it isn't RECIP (precise is the same), and it isn't PME's reciprocal part. The gap is in
  the direct-space nonbonded energy: +2.01e-6 vs +1.76e-6, about 14% more error. The spread across
  contexts is about 1e-7.
- Direct space sums the per-pair energies in float in each thread (`energy += tempEnergy`) and
  then across the energy buffer. Metal's computeNonbonded is its own kernel (nonbonded.metal), and
  its summation order can differ from OpenCL's. Likely cause, not proven: summation order in float.
  Candidate fix, not done: accumulate the pair energy in mixed or in Kahan form. It isn't a
  one-liner, so it is left for a decision.
- The total minus the sum of groups is about 9e-8 on both platforms: the reduction plus
  nondeterminism.

**4. Plain LangevinIntegrator in the sweep.**
- capture.py adds "dhfr-langevin": dhfr with `mm.LangevinIntegrator(300 K, 1/ps, 2 fs)` (the Python
  type is LangevinIntegrator).
- In this OpenMM, LangevinIntegrator is an empty subclass of LangevinMiddleIntegrator
  (LangevinIntegrator.h:40–45). The capture agrees: its 15 programs match the other configurations'
  programs by source hash, and none is new. Across all 7 configurations there are 47 unique
  programs, the same set as the 016c capture.
- strictnarrow.py on its 15 programs, with fast and with precise defines (identical): 12 clean, and
  the rest hold only the known storage narrowings (posqCorrection ×3, LocalCoordinatesSite
  fresult). literals.py: only the two known harmless hits.
- Capture in `~/lab/capture-5722/` (build 5722f98a7).

**5. Timing hygiene.**
- 016c, 016d and 016e ran at nice 5. They were launched with zsh `&`, and zsh's BG_NICE lowers
  background jobs by 5. Both platforms in each run had the same nice, so the ratios stand; the
  absolute numbers may be low.
- mini-b.sh, repeats.sh and abrecip.sh now refuse to run at any nice value other than 0, and write
  it as the first line of host.txt. Launch: `ssh <mini> 'sh -c "nohup sh ~/lab/SCRIPT <label> >
  ~/lab/SCRIPT.log 2>&1 &"'`.
- Checked: a zsh `&` launch prints "running at nice 5, not 0" and creates no results directory.
- Re-run of repeats.sh at nice 0 (`~/lab/results-016g-20260923T060618Z/`; host.txt: "nice 0"; no
  thermal or performance warnings):

| WU | Metal single ns/day | OpenCL single ns/day | Metal/OpenCL |
|---|---|---|---|
| dhfr-implicit | 199.36, 198.96, 198.86: 199.06 ± 0.26 | 191.74, 192.50, 192.35: 192.20 ± 0.40 | 1.036 (1.040 / 1.034 / 1.034) |
| nav | 11.30, 11.28, 11.29: 11.29 ± 0.01 | 11.01, 11.01, 11.00: 11.01 ± 0.01 | 1.026 (1.026 / 1.024 / 1.027) |

- The same as 016d at nice 5 (1.037 and 1.026). With the mini otherwise idle, nice 5 cost nothing
  measurable, so the 016c/d/e numbers stand.

### 2026-09-23 — DPDIntegrator and GayBerneForce: PRIVATE address space (commit 677e98030)

- dpd.cc and gayBerne.cc pass pointers to a thread's own variables (`RandomState*`, `int*
  neighborBuffer`, `AtomData*`, `real (*m)[3]`, `real3* force1`, ...). MSL needs an address space on
  every pointer, local variables included.
- New kernel macro `PRIVATE`: empty in the OpenCL, CUDA and HIP preludes, and `thread` on Metal.
  dpd.cc gets 3 uses and gayBerne.cc 11 (function parameters, plus the three local `real (*a)[3]`
  pointers in computeOneInteraction). The developer guide's macro table lists it.
- Catch: Metal's prelude had `#define thread _mmThread`, because 18 common kernels use `thread` as
  a variable name. That define also rewrote `PRIVATE` → `thread` → `_mmThread`. Checked with mslc:
  no spelling of the thread address space survives the define (`__attribute__((address_space(0)))`
  still gives "pointer type must have explicit address space qualifier", and `__thread` isn't
  supported).
- So createLibrary now renames the word `thread` to `_mmThread` in the kernel source text and in
  the define values, and the global define is gone. The preprocessor runs later, so PRIVATE still
  expands to the real keyword.
  - None of Metal's own kernel files uses `thread` as a keyword; only comments mention it, and
    renaming a comment is harmless.
  - The prelude (common.metal, df64.metal) isn't renamed.
- Shared-code footprint: 1 line in each of 3 preludes, 14 PRIVATE markers in 2 common kernels, and
  the developer guide. No behaviour change on OpenCL/CUDA/HIP, where the macro is empty. CUDA and HIP
  are untested here; OpenCL is checked below.
- Mini, build of 677e98030 (the synced tree, committed unchanged):
  - `ctest -R "DPDIntegrator|GayBerne"`: Single and Mixed of both pass (4 of 4).
  - Full `ctest -R TestMetal -j1`: "100% tests passed out of 110", covering every kernel that uses
    `thread` as a variable.
  - No OpenCL tests are registered in this build, so OpenCL is checked from Python.
  - `gayberne.py` (20 random ellipsoids): relative force error against Reference is OpenCL 9.0e-7
    and Metal 1.18e-6. Energy −1.61146 kJ/mol on all three.
  - `dpdtemp.py`: a 200-particle ideal gas in a 3 nm periodic box, DPD at 300 K with friction 1/ps
    and 1 fs steps. Mean temperature over 10–20 ps, 3 seeds each: Reference 302.1 /
    301.2 / 298.7, OpenCL 296.2 / 300.0 / 305.9, Metal 297.9 / 300.3 / 302.6.
  - The first version of dpdtemp.py used an open (non-periodic) box. The gas expanded beyond the
    cutoff, so the thermostat stopped acting and every platform froze at 330–400 K. Learning: a
    thermostat check needs a periodic box.
- Not covered: AMOEBA and other plugins pass unqualified private pointers too (for example
  gkPairForce1.cc `real3* force`). They need PRIVATE when those plugins get Metal platforms.

### 2026-09-23 — energy minimization in mixed precision: single-block reductions (option A)

- Problem: in mixed precision the LBFGS minimizer sums into doubles with `atomicAddMixed`, which
  needs 64-bit float atomics (CUDA/HIP `atomicAdd`, OpenCL a 64-bit CAS). Metal has neither, so
  8829d724c refused the minimizer in mixed.
- Change:
  - CommonMinimizeKernel sets `singleBlockReductions = mixedIsDouble && !getSupports64BitGlobalAtomics()`,
    where it used to throw "Double precision is not supported on devices that do not support 64 bit
    atomic operations".
  - When it is set, the program gets `-DSINGLE_BLOCK_REDUCTIONS`, and the 9 kernels that call
    atomicAddMixed launch as one thread block through a new `executeReduction`.
  - atomicAddMixed's first branch under that define is a plain `*target += value`.
  - Every other case keeps the same launches and the same preprocessed source.
  - The Metal-only throw in MetalKernelFactory and the ctest expect-error are removed.
- Upstream already runs gradNorm, getConstraintError and getScale's largeGrad path as one block
  (`execute(threadBlockSize, threadBlockSize)`). All minimizer kernels loop grid-stride, so one block
  covers every variable.

#### Single-writer audit (condition 1)

Every atomicAddMixed call is `if (LOCAL_ID == 0) atomicAddMixed(target, reduceAdd(...))`: one call
per block, so one block means one writer per launch. Per kernel, from reading minimize.cc and the
host sequence in CommonMinimizeKernel.cpp:
- No kernel has a "last block" counter.
- Nothing combines values across blocks in any other way.
- No target gets a second non-atomic write in the same launch.
- No target is read in the launch that accumulates it.

| Kernel (launch) | Target | Zeroed by (earlier launch) | Other accesses in the same launch |
|---|---|---|---|
| getConstraintEnergyForces (evaluateGpu) | `returnValue` | restorePos, `GLOBAL_ID == 0` (every evaluateGpu starts with it); CPU fallback: `cc.clearBuffer(returnValue)` | none; convertForces may later overwrite it with FLT_MAX (a later launch) |
| getScale, non-largeGrad path | `scale[end]`, `returnValue` | getDiff, `GLOBAL_ID == 0 && !largeGrad` | also zeroes `alpha[0..NUM_VECTORS]`, a different target; neither target is read. largeGrad path is already one block with plain stores |
| reinitializeDir | `alpha[vectorIndex]` | getScale | thread 0 writes `returnValue`, a different target; alpha is not read |
| updateDirAlpha | `alpha[vectorIndex2]`, the cyclic predecessor of vectorIndex1 | getScale | reads `alpha[vectorIndex1]`, never the target (NUM_VECTORS = 6); each index is accumulated by one launch and read only by later ones |
| scaleDir | `alpha[NUM_VECTORS]` | getScale | reads `alpha[vectorIndex]` and `returnValue`, not the target. Upstream puts the result in the extra slot precisely so that no block reads a target another block adds to. `GLOBAL_ID == 0 ? innerScale : 0` adds innerScale once |
| updateDirBeta | `alpha[vectorIndex2]`, vectorIndex1 + 1 | not zeroed: it adds onto the value the alpha pass finished in an earlier launch, by design | reads `alpha[vectorIndexAlpha]` (vectorIndex1 or NUM_VECTORS), never the target |
| lineSearchSetup | `lineSearchData[LS_DOT_START]` | resetLineSearchData (initializeDir / updateDirFinal, `GLOBAL_ID == 0`) | also writes `returnFlag` and `gradNorm = 0`, different targets |
| lineSearchStep, LS_SUCCEED branch | `gradNorm` | lineSearchSetup / lineSearchContinue `*gradNorm = 0` | returns right after; the other branch writes `returnFlag` and `lineSearchData[LS_DOT] = 0`, which this branch doesn't touch |
| lineSearchDot | `lineSearchData[LS_DOT]` | lineSearchStep `GLOBAL_ID == 0`; CPU fallback restores it from lineSearchDataBackup | reads `LS_STEP`, `LS_DOT_START`, `returnValue`, not the target |

- getDiff reads `gradNorm`, but in a later launch than the one that accumulates it.

#### The df64 → long cast (condition 2)

- getConstraintEnergyForces converts forces to fixed point with `(mm_long) (kdr * scale * delta.x)`.
  df64's `operator long` was already exact, not `(long) hi`:
  - It floors (or, if negative, ceils) the whole df64, then returns `(long) t.hi + (long) t.lo`.
  - A whole df64 has integral hi and lo.
  - df64 `floor` covers both cases: hi not integral (then |lo| < ulp(hi)/2 can't cross an
    integer), and hi integral with a fractional lo.
- It had no runtime test. `testLongConversion` (TestMetalMixedPrecision, mixed) now checks:
  - 12 values that df64 holds exactly, each with both signs: 0, 0.75, 1.5, 3−2^-30, 2^24−0.5,
    2^31+0.25, 2^40+0.75, 1234.5·2^32, 2^52−0.5, 2^53−1, 2^53+2, 2^62+2^40. Each must survive the
    round trip exactly and cast equal to the host's `(long long)` of the double.
  - 1000 random values up to 2^62, with random sign. Each is rounded to df64 on load, so it is
    compared with the host cast of the value the kernel stored back (and must be within 1e-14 of
    the input).
- Mutation check. With the cast changed temporarily, and only the test target rebuilt:
  - `return (long) hi;` fails: "Expected 2, found 3" (3−2^-30).
  - Floor, then `(long) t.hi` only, fails: "Expected 4503599627370495, found 4503599627370496".
  - Restored and rebuilt, the test passes.
- Condition 5: minimize.cc needed no df64.metal additions. `+=` on `volatile threadgroup df64`
  (reduceAdd's temp) and `explicit operator long()` both already existed. The new runtime test
  covers the cast. The volatile `+=` is exercised by the full minimizer test in mixed.

#### Single and non-Metal kernel source unchanged (condition 4)

- Metal single, full program source as saved by OPENMM_SAVE_TEMPS (`minsrc.py`, which minimizes 3
  particles with a bond and a constraint):
  - Baseline from the 677e98030 install: `~/lab/minsrc-before/minimize-single.metal`. After:
    `~/lab/minsrc-after/`.
  - The raw text differs only by the minimize.cc edit itself: the new `#if
    defined(SINGLE_BLOCK_REDUCTIONS)` branch and the reworded Metal comment.
  - The define block is identical. There is no SINGLE_BLOCK_REDUCTIONS in single; the mixed program
    has it.
  - After stripping `#include <metal_stdlib>` and running `clang -E -P -x c++
    -D__METAL_VERSION__=310`, the two single programs are byte-identical (661 lines, sha256
    04b96efb…).
- minimize.cc alone, preprocessed old against new with `clang -E -P`: identical for every other
  configuration. Each configuration hashes differently, so each branch really was selected.
  - CUDA single, mixed and double.
  - HIP single and mixed.
  - OpenCL single, mixed and double.
  - Metal single.
- Host launches on CUDA, OpenCL and HIP are unchanged, because singleBlockReductions is false
  whenever the device has 64-bit atomics.
  - Behaviour change: an OpenCL device without 64-bit atomics used to throw in mixed or double
    precision, and now takes the single-block path.

#### Tests (build of f9347f6c5 = the synced tree; installed to prefix-openmm-metal / venv-metal)

- `ctest -R "TestMetalLocalEnergyMinimizer|TestMetalMixedPrecision"`: 4 of 4. LocalEnergyMinimizerMixed
  now runs the whole shared test (harmonic bonds, large system with constraints, virtual sites, large
  forces, force groups, massless particles, reporter), with no expected error.
- Full `ctest -R TestMetal -j1`: 108 of 110. The two failures are the known stochastic barostat tests:
  - MonteCarloBarostatSingle: "Expected 1.5, found 1.34655".
  - MonteCarloFlexibleBarostatMixed: "Expected 3, found 3.67115".
  - Neither test minimizes, and neither runs minimize.cc code.
  - Rerun 3 times: BarostatSingle passed 3 of 3; FlexibleBarostatMixed passed 2 of 3.
- The raw ctest output is in `~/lab/ctest-minA.txt`.

#### Minimization of the work units (results-016h-20260923T*, `minimize.sh` / `minwu.py`)

- Method:
  - Start state of each work unit; tolerance 10 kJ/mol/nm; maxIterations 0.
  - Wall time is host wall around `minimize()` at nice 0, after a one-iteration warm-up that
    compiles the kernels.
  - A second run with a reporter counts iterations over all 4 restraint passes. The first attempt
    counted only the last pass (the reporter's iteration number restarts each pass), so it was
    aborted and rerun.
  - Each final state is scored on Reference in double precision: energy, plus force with its
    components along constraints projected out, per rigid cluster, by least squares. From that:
    - RMS over particles, the quantity the tolerance bounds (`|g| <= tol·sqrt(N)`);
    - max over particles, which the tolerance doesn't bound.
- Start energies (Reference): dhfr −337089.6, nav −1720827.8 kJ/mol.

| WU | run | final E (platform) | final E (Reference) | RMS F | max F | iterations | wall s | ms/iteration |
|---|---|---|---|---|---|---|---|---|
| dhfr (23558) | Metal mixed | −381325.77 | −381326.55 | 5.64 | 119.8 | 2303 | 28.02 | 12.2 |
| | Metal mixed, repeat | same positions (sha 82891d9e…) | | | | 2303 | 28.02 | |
| | Metal single | −381926.54 | −381927.29 | 6.46 | 114.2 | 3111 | 9.76 | 3.1 |
| | CPU | −381385.49 | −381385.44 | 5.64 | 89.1 | 2109 | 24.50 | 11.6 |
| nav (173112) | Metal mixed | −2283374.07 | −2283374.11 | 8.62 | 1460.4 | 2999 | 263.94 | 88.0 |
| | Metal mixed, repeat | same positions (sha eedb6028…) | | | | 2999 | 263.89 | |
| | Metal single | −2286220.89 | −2286220.81 | 8.15 | 1132.0 | 3674 | 58.32 | 15.9 |
| | CPU | −2280000.19 | −2279999.98 | 9.28 | 571.2 | 2180 | 300.15 | 137.7 |

- Every run reaches the tolerance: the RMS of the Reference-scored force is 5.6–9.3 against 10.
  Max constraint error is under 1.1e-5.
- Mixed is deterministic.
  - The repeat ends at bit-identical positions on both work units.
  - The reporter run ends there too.
  - Single and CPU don't: float atomics and threads make them run-to-run different.
  - The two mixed dhfr runs print energies 7e-10 kJ/mol apart at identical positions. That is
    energy summation order in the force kernels, not the minimizer.
- Final energies against CPU. The runs stop in different nearby minima, so compare them against
  the energy drop (dhfr about 44,000, nav about 560,000 kJ/mol):
  - dhfr: mixed is 60 above CPU (0.14% of the drop); single is 541 below it (1.2%).
  - nav: mixed is 3374 below CPU (0.6% of the drop); single is 6221 below it (1.1%).
- Max per-particle force is the outlier. nav mixed ends with one particle at 1460 kJ/mol/nm (single
  1132, CPU 571), which the RMS criterion allows.

#### Where mixed minimize time goes (the 25% gate): **gate exceeded, about 80% on nav**

- Temporary instrumentation (never committed; the committed build was reinstalled afterwards, and
  `MINIMIZE_PROFILE` is absent from the installed plugins):
  - Each single-block launch and each GPU force evaluation is timed between device syncs.
  - The cost of one empty sync per launch is measured and subtracted.
  - `minprof.py`; output in `minprof-016h.txt`.
- The syncs add wall time: nav mixed 285 s instrumented against 264 s. So the shares below are
  against the instrumented wall, and are cross-checked against the uninstrumented wall.

| run | wall s | single-block launches | their time s (−sync) | per launch ms | force evals | force s | per eval ms |
|---|---|---|---|---|---|---|---|
| dhfr mixed | 43.09 | 41709 | 30.91 | 0.74 | 2426 | 7.44 | 3.07 |
| dhfr single (multi-block, float atomics) | 20.96 | 45485 | 10.89 | 0.24 | 2709 | 6.05 | 2.23 |
| nav mixed | 285.13 | 54271 | 226.85 | 4.18 | 3134 | 57.31 | 18.29 |
| nav single (multi-block, float atomics) | 73.71 | 65291 | 17.62 | 0.27 | 3806 | 50.85 | 13.36 |

- nav mixed: the single-block kernels are 80% of the instrumented wall.
  - Cross-check: the uninstrumented 264 s minus the force evaluations (≤ 57 s) leaves ≤ 207 s,
    or ≤ 78% for everything else.
  - Either way the share is about 80%, well above the 25% gate. Per launch, one block of 256 threads
    is 15× slower than the multi-block float version (4.18 against 0.27 ms).
- nav minimization takes 264 s in mixed, against 58 s in single and 300 s on CPU. Correct, but
  4.5× slower than single.
- Per the plan, I stop here and report before starting option C (two-pass reduction).
  - Rough estimate for C, not a measurement: mixed launches cost what single's do, or 2–3× that for
    df64 arithmetic and IEEE packing. That gives 54271 × 0.3–0.8 ms ≈ 15–45 s, plus 57 s of force
    evaluations: about 75–100 s on nav, against 264 s now and 58 s single.

#### Learnings (2026-09-23)

- zsh doesn't word-split unquoted parameters. `for d in "-DA -DB"; do clang $d` passes one argument,
  and `set -- $a` sets only `$1`. It bit twice here: the preprocessor comparison looked identical
  across precisions, and a profile loop ran nothing. Use `${=d}`, or run the loop under `sh -c`.
  Distinct hashes per configuration are what exposed the first one.
- MinimizationReporter's iteration number restarts at 0 on each restraint pass. Count calls to get
  total iterations.
- A mutation check is the way to show a test catches the bug it is meant for. Break the code in the
  specific way named (here `(long) hi`, and floor without lo), rebuild just the test target, watch
  it fail, then restore.

### 2026-09-23 — upstream-shaped history (local branch `metal-upstream`, not pushed)

Ten trailer-free commits on 3c9effc96. `git diff metal metal-upstream` is empty (0 bytes), so the
tree is `metal` at f9347f6c5.

| # | Commit | Subject |
|---|---|---|
| 1 | 0c3e7731e | Add metal-cpp headers |
| 2 | 75ab1aa64 | Fix VkFFT's Metal backend for use with metal-cpp (every hunk inside `VKFFT_BACKEND==5`) |
| 3 | 6afd95bba | Cast zero literals to mixed in conditional expressions |
| 4 | 5c725738f | Make ComputeContext::doubleToString virtual (ABI note in the message) |
| 5 | 4c1980672 | Add a PRIVATE address space macro for pointers to private variables |
| 6 | 96eeefed2 | Let the minimizer reduce without 64 bit atomics |
| 7 | 123d96c08 | Add a Metal implementation of atomicAddMixed |
| 8 | 038101955 | Add a Metal platform |
| 9 | 89f91d7e4 | Add Metal platform tests |
| 10 | 915bccb92 | Document the PRIVATE address space macro |

- Each commit builds from clean on the M3 Pro (Ninja, OpenCL on, no Python wrappers).
  - Commits 1–8 give 212 test programs and no Metal tests. Commits 9–10 give 267, 55 of them Metal.
  - Commits 9 and 10 were reworded after the build; their trees are the ones built.
  - CUDA and HIP can't be built on a Mac. Their edits are the PRIVATE macro (empty) and the minimizer,
    which preprocesses byte-identically.
- Full Metal suite on the tip, M3 Pro (18 GPU cores), macOS 27: 107/110.
  - BrownianIntegratorMixed is the stochastic failure; it passes 4/4 on rerun.
  - LocalEnergyMinimizer testLargeForces (`maxdist > 1.0`, line 229) fails in single and mixed. It
    fails the same way for OpenCL single on an unmodified 3c9effc96 build on this machine, so it is
    not ours. Reference and CPU pass, and it passes on the M2.
- PR description draft: `drafts/2026-09-23-metal-platform-pr.txt`. It has a placeholder for the AI
  disclosure, which the owner writes.

#### Upstream hygiene, not done (size estimates)

- License headers (S, mechanical). 84 files carry "Portions copyright (c) 2026 the Authors." with
  blank Authors and Contributors lines. The owner must supply the names. The 6 .metal kernels and
  the 2 CMakeLists have no header, which matches OpenCL.
- Licenses.txt (XS). Section 2 names only CUDA and OpenCL (add Metal). Add a section for metal-cpp
  (Apache 2.0, compatible with LGPLv3).
- User guide (S, 40–60 lines). There is no Metal section in `usersguide/library/04_platform_specifics.rst`
  (Precision, DeviceName, UseCpuPme, TempDirectory; no DeviceIndex). The getting-started
  requirements need macOS 15 and Apple7+. The developer guide has chapters for OpenCL and CUDA;
  whether Metal needs one (the prelude, the rewriter, df64) is peastman's call (M if so).
- Trim metal-cpp (M, risky). It is 127 files and 35k lines, but `Metal.hpp` includes every Metal
  header, and VkFFT needs Foundation and QuartzCore. Trimming means hand-pruning the umbrella
  headers against each metal-cpp update. Recommend keeping it whole and saying so in the PR.
- Older SDKs (S to verify). metal-cpp is the macOS 27 release, and the deployment target defaults
  to 10.7. Unverified: a build against the oldest SDK that conda-forge uses for osx-arm64.
- CI (S to M). GitHub's macOS runners are virtualized. If their GPU isn't Apple7, the platform won't
  register and every Metal test fails. Needs a check, and possibly a skip-if-unavailable in the
  test wrappers.
- Rerun on the final tip on the mini (S, about 1 h of mini time): the full suite, the FAH table (now
  from 5fe5b9492), and per-commit builds with the OpenCL tests.
- maxShortList 1024 vs 8192, and no PRUNE_BY_CUTOFF (S to M): benchmark or restore parity.
- The rewriter's comment stripping, plus a unit test (S). The `thread`→`_mmThread` rename also
  touches comments (cosmetic).
- sort.metal mixes binding styles (XS).
- Split commit 8 (6.6k lines) into context/arrays/rewriter, then kernels (M). Only if peastman
  asks; each part must still build.
- VkFFT: send METAL_PATCHES.txt to VkFFT upstream (S), so the vendored copy converges.
- QTB in mixed: expected-error test vs skipping (XS, reviewer preference).
- testLargeForces on M3: pre-existing, OpenCL too. Worth an upstream issue, separate from this PR
  (S to investigate).
- Non-blocking uploads, minimizer option C: performance, not blocking.
- AI_POLICY.md (owner only). Disclosure in the PR, plus the owner confirms they understand the code
  and have the legal right to submit it, and answers review questions without AI.

### 2026-09-23 — docs commits on `metal` (b64ed233a, 87d9bc487, 55a34bad4), related-powers fix (uncommitted)

- Docs only, no builds (the laptop is busy with the three-chip benchmark, and the verifier has
  the mini):
  - Licenses.txt, plus Apache-2.0.txt for metal-cpp.
  - The user guide's Metal section and getting-started line.
  - The platform lists in 01_introduction, 02_running_sims and 02_compiling.
- The integer-power fix ("Known deviations" item 3 above) is written but not built.
  - ExpressionUtilities.cpp POWER_CONSTANT declares each related power like the primary one:
    `make_<tempType>(0.0f)` for vector temps, instead of `tempType t = 0.0f`.
  - Lepton rewrites ^2, ^3, ^0.5 and ^-1 to SQUARE, CUBE, SQRT and RECIPROCAL, so the path needs
    two different integer powers ≥ 4 of the same base.
  - New test: testRelatedPowers in tests/TestCustomIntegrator.h, per-DOF `x^4+x^5` at 1e-5.
  - OpenCL C accepts `double3 t = 0.0f` through scalar widening. CUDA/HIP vector types are plain
    structs, so they likely had the same bug; unverified, since they can't be built on a Mac.
  - Committed as 361452c5c after the machines were released:
    - Laptop (-j8), $S/wt + patch: TestReferenceCustomIntegrator Done; TestOpenCLCustomIntegrator
      single Done (mixed/double: no compatible OpenCL platform); TestMetalCustomIntegrator single and
      mixed Done.
    - Mini, ~/lab/openmm-metal synced (code blobs = f9347f6c5 before the sync; the two files
      match by hash afterwards): TestMetalCustomIntegrator single and mixed Done. The build is not
      installed, so prefix-openmm-metal / venv-metal are still f9347f6c5.
    - There's no TestCpuCustomIntegrator: the CPU platform runs CustomIntegrator on Reference
      kernels, which don't go through ExpressionUtilities.
    - Mutation (the one line reverted, test kept): Metal mixed fails with "no viable conversion
      from 'float' to 'df64_3'". Metal single and OpenCL single still pass, since both widen a
      scalar.
    - OPENMM_SAVE_TEMPS dump with the fix: `double3 temp9 = make_double3(0.0f);` (first power)
      and `double3 temp10 = make_double3(0.0f);` (related power), so the test reaches the line.

### 2026-09-23 — testLargeForces across chips

- Mini, pristine 3c9effc96 (~/lab/base-3c9e, git archive, OpenCL tests on):
  TestOpenCLLocalEnergyMinimizer single passes 3/3. Reference and CPU pass. OpenCL mixed/double:
  no compatible platform.
- Laptop M3 Pro, pristine 3c9effc96 ($S/basebuild): OpenCL single fails at :229 3/3 more (4/4 in
  all).
- M3 Ultra (017, f9347f6c5 build): Metal single, Metal mixed and OpenCL single fail 3/3 at :229.
  Reference and CPU pass.
- Conclusion: an M3-family failure in upstream code, not in ours. Issue draft updated:
  drafts/2026-09-23-testlargeforces-issue.txt.

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
- The global `#define thread` in the prelude.

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
  - the three WUs as shipped: dhfr-implicit (Langevin, GBSA-OBC), dhfr and nav (PME, SHAKE/SETTLE,
    Langevin);
  - dhfr with LangevinMiddle and MonteCarloBarostat (frequency 5);
  - a TIP4P-Ew 2.5 nm box (virtual sites, SETTLE, PME, barostat, LangevinMiddle);
  - a 4-atom fully constrained chain (CCMA, Verlet, CMMotionRemover).
- Together they cover Verlet, Langevin, LangevinMiddle, SETTLE, CCMA and SHAKE, CMMotionRemover,
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
   - Affected: CustomIntegrator expressions that use these functions (its globals and per-DOF values
     are mixed; custom forces compute in real and are unaffected), and QTBIntegrator (qtb.cc:154, `COS(f*dt)` in the noise spectrum).
   - QTB is unavailable in mixed precision on Metal (team-lead decision). TestMetalQTBIntegratorMixed
     expects the error (see "Test wrappers vs OpenCL").
   - The fix is df64 sin/cos (the deferred work). qtb.cc:139's twiddle table uses float arguments
     and would also need it.
2. Double constants in expressions.
   - Fixed (135f194ca): ComputeContext::doubleToString is virtual, and MetalContext writes a
     constant that a float can't hold as `df64(hi, lo)` when a double constant is requested in mixed
     mode. This covers CustomIntegrator globals and per-DOF expressions and NoseHoover's BOLTZ.
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

- Metal single and mixed reproduce 016b's drift and rms to every printed digit, since Metal runs are
  deterministic.
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
| constants: CustomIntegrator 0.1 and 0.7 at 1e-12 | FAIL | pass |

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

# Where Metal can beat Apple's OpenCL by 2x or more on the M3 Ultra

Research lane, 2026-09-24. Read-only: I ran nothing on any GPU. Tiers: **verified** means I read the code, binary or document; **lab** means one of our experiments measured it; **reported** means a source says so; **inference** means my reasoning.

## Short answer

Only one workload class clears 2x with confidence, and it wins by refusal, not speed. That class is anything that needs mixed precision. OpenMM's OpenCL won't run mixed or double on Apple GPUs, so those users fall back to the CPU platform. On the M2 the GPU ran 6 to 7.5x faster than the CPU (lab 001).

A second class could reach 2x once one lever lands: small systems whose steps block on the host. Examples are CustomIntegrator `computeSum` steps, per-step energy reads and Python `step(1)` loops. Metal's advantage there today is about 1.3x. A spin-then-block wait could double that (inference from labs 008 and 024).

Everything else I checked lands between 1.0 and 1.6x, or needs measuring before anyone claims anything: AMOEBA, custom forces, multiple simulations, and PME-heavy settings. Very large systems could be a capability win, but the OpenCL allocation cap on the M3 Ultra is unknown, and a query of about 10 lines settles it.

## Ranked candidates

| # | Workload | Mechanism | Expected Metal/OpenCL | Confidence |
|---|---|---|---|---|
| 1 | Anything in mixed precision, including FAH-style runs, free energy and NPT production | OpenCL refuses mixed and double without cl_khr_fp64, so users fall back to the CPU platform | 4 to 8x against the CPU fallback | high |
| 2 | Small systems that sync with the host every step | Every sync costs more on OpenCL (blocking wake, readback through a copy kernel) | 1.3x now, about 2x with a spin wait | medium |
| 3 | Very large systems (10M+ atoms) | OpenCL's max single allocation may sit far below Metal's `maxBufferLength` | Runs against fails, or nothing | unknown until queried |
| 4 | PME-dominated settings (short cutoff, LJPME, tight tolerance) | Apple9 float atomics make spreading 2.6x faster; OpenCL 1.2 has no float atomics | 1.2 to 1.6x | medium, needs lever 1 |
| 5 | AMOEBA | One host sync per induced-dipole iteration; mixed isn't possible on OpenCL | Single 1.1 to 1.3x; mixed against the CPU is large | low for single; Metal has no AMOEBA yet |
| 6 | CustomNonbondedForce and CustomGBForce with heavy expressions | Metal compiles EXP and LOG to fast intrinsics; OpenCL uses native_exp only if its accuracy test passes | 1.0 to 1.3x | low |
| 7 | Several simulations sharing the GPU | No structural difference found | 1.0 to 1.1x | low |
| 8 | Context creation and kernel compile time | Both compile source at runtime through the same AIR backend | unknown | low, cheap to measure |

## 1. Mixed precision: OpenCL can't run it, so the fallback is the CPU

Mechanism:
- Verified. OpenCL throws "This device does not support double precision" for mixed or double when `cl_khr_fp64` is missing (`/Users/amir/code/mini/hipdelta-gbsa/platforms/opencl/src/OpenCLContext.cpp:213-216`).
- Lab 025. The M3 Ultra's OpenCL has no `cl_khr_fp64` (CL_DEVICE_DOUBLE_FP_CONFIG 0x0). benchmark.py printed "No compatible OpenCL platform is available" for mixed (`experiments/025-best-metal-vs-opencl/results/m3ultra-20260924T1701Z/README.txt`).
- Verified. Metal mixed runs through df64. Metal still reports `supportsDoublePrecision() == false` (`MetalPlatform.cpp:154-156`), so double isn't a Metal win either.

Who needs mixed:
- Reported, via `research/2026-09-24-fah-precision.md`. FAH staff say every GPU core needs FP64. Core22 launched as "Precision: Mixed", and perses writes `Precision=mixed`. Peter Eastman says mixed means double energy accumulation and integration.
- Inference. Beyond FAH, mixed is the default advice for alchemical free energy runs (openmmtools and perses), for long NVE, and for tight energy comparisons.

What the user falls back to:
- Reported (`research/2026-09-23-fah-core-requirements.md`, `2026-09-23-fah-client-apple-gpu.md`). FAH on macOS runs only the a8 CPU core, which is GROMACS-based, and no macOS GPU core has ever shipped.
- An OpenMM user falls back to the CPU platform, which reports its precision as mixed (lab 001).

Evidence for the size of the gap:
- Lab 001, M2 with 8 CPU cores: OpenCL single ran apoa1rf at 59.5 ns/day against 7.89 on the CPU platform (7.5x), and apoa1pme at 46.4 against 7.59 (6.1x).
- Lab 025, M3 Ultra: Metal mixed ran apoa1pme at 168.6 ns/day and amber20-dhfr at 415.8.
- Inference: the Ultra's 28 CPU cores (20P+8E) should run the CPU platform about 3 to 4x faster than the M2's 8, which gives an expected 4 to 8x.

Benchmark (needs the lease; the CPU run loads all 28 cores, so hold it while no build is running):

```
# Metal mixed vs CPU platform, same systems, 3 rounds x 30 s, order reversed each round
python benchmark.py --platform Metal --precision mixed --test pme,apoa1pme,amber20-dhfr,amber20-cellulose --seconds 30 --style table
python benchmark.py --platform CPU --test pme,apoa1pme,amber20-dhfr,amber20-cellulose --seconds 30 --style table
python benchmark.py --platform OpenCL --precision mixed --test pme   # record the refusal text as evidence
```

Report the ratio, and add the CPU platform's thread count (`CpuThreads` property) and the load. The claim holds if the ratio is 2x or more on every test.

## 2. Small systems that sync with the host every step

Mechanism:
- Verified. A CustomIntegrator `computeSum` step runs a reduction kernel, then calls `summedValue.download(&value)`, a blocking readback, every time it executes (`platforms/common/src/CommonIntegrateCustomStepKernel.cpp:744-754`). `IfBlockStart` and `WhileBlockStart` evaluate on the host (`:771-776`). openmmtools-style integrators that track kinetic energy, shadow work or GHMC acceptance hit this every step (inference about typical integrator scripts). `getState(getEnergy=True)` inside a Python loop does the same.
- Verified, OpenCL side (disassembly of `AppleMetalOpenGLRenderer`, previous message). A blocking read or wait commits through the private `commitAndWaitUntilSubmitted`, then waits with a blocking `waitUntilCompleted` or event wait. Buffer copies run as internal compute kernels (`GLDQueueRec::copyFromBufferToBuffer` calls `dispatchThreads`).
- Lab 008, M3 Ultra, 50 kernels per step. With a sync every step, Metal took 0.567 ms and OpenCL 0.651 ms, against about 0.336 ms pipelined for both. Sync overhead is therefore about 0.24 ms per step on Metal and 0.32 ms on OpenCL. Readback from a shared buffer took 0.95 us, against 170 us from a private one.
- Lab 024. A blocking wait wakes the host 90 to 110 us after the GPU finishes. Spinning wakes it in 22 us. 6df2b8bcb still blocks (`MetalEvent.cpp:55`, `waitUntilSignaledValue(value, 100)`).
- Inference. With a spin-then-block wait (spin about 50 us, then block), Metal's sync overhead drops by about 80 us to roughly half of OpenCL's. On a system whose GPU work per step is 50 to 100 us, that is about 2x end to end. The lever is small: one function in `MetalEvent::wait`. It burns one host core while spinning.

Benchmark (single precision on both, so OpenCL can run it):

```python
# sync_bench.py <platform> ; uses benchmark.py's gbsa system (DHFR implicit, 2489 atoms) or an alanine dipeptide box
import openmm as mm, openmm.app as app, openmm.unit as u, time, sys
pdb = app.PDBFile('5dfr_minimized.pdb')            # same file benchmark.py gbsa uses
ff = app.ForceField('amber99sb.xml', 'amber99_obc.xml')
system = ff.createSystem(pdb.topology, nonbondedMethod=app.NoCutoff, constraints=app.HBonds)
integ = mm.CustomIntegrator(0.002)                 # velocity Verlet + one computeSum per step
integ.addGlobalVariable('ke', 0); integ.addPerDofVariable('x1', 0)
integ.addUpdateContextState()
integ.addComputePerDof('v', 'v+0.5*dt*f/m'); integ.addComputePerDof('x', 'x+dt*v')
integ.addComputePerDof('x1', 'x'); integ.addConstrainPositions(); integ.addComputePerDof('v', 'v+0.5*dt*f/m+(x-x1)/dt')
integ.addConstrainVelocities(); integ.addComputeSum('ke', '0.5*m*v*v')
plat = mm.Platform.getPlatformByName(sys.argv[1])
ctx = mm.Context(system, integ, plat, {'Precision': 'single'})
ctx.setPositions(pdb.positions); ctx.setVelocitiesToTemperature(300)
integ.step(200)
t = time.perf_counter(); integ.step(5000); dt = time.perf_counter() - t
print(sys.argv[1], 'us/step', 1e6*dt/5000)
```

Run it three ways on both platforms: as written, with the `computeSum` line removed (the no-sync control), and as a Python loop of `step(1)` plus `getState(getEnergy=True)`. Then repeat on Metal with a spin-wait build. The claim needs Metal/OpenCL of 2x or more in us/step on the sync variants, with the no-sync control near 1.1x.

## 3. Very large systems and the OpenCL allocation cap

Mechanism:
- Verified (disassembly). `gldCreateDevice` in the renderer stores `recommendedMaxWorkingSetSize`, and separately `maxBufferLength >> 2`, in its device config (`AppleMetalOpenGLRenderer`, around 0xBA58 to 0xBA6C).
- Reported. An M4 clinfo shows "Global memory size 11453251584 (10.67GiB)" and "Max memory allocation 2147483648 (2GiB)" ([FAH forum t=43406](https://forum.foldingathome.org/viewtopic.php?t=43406), Artoria2e5, 2025-12-17).
- Inference. That fits CL_DEVICE_MAX_MEM_ALLOC_SIZE = `maxBufferLength/4`, and CL_DEVICE_GLOBAL_MEM_SIZE = `recommendedMaxWorkingSetSize`. Metal has no /4: OpenMM Metal can allocate up to `maxBufferLength` per buffer.
- What hits the cap (verified sizing, inferred numbers). The biggest per-atom-scaled buffer is `interactingAtoms`: 32 ints per tile, with `maxTiles = 1.2 x` the observed count after the first step (`OpenCLNonbondedUtilities.cpp:283,412`). My rough estimate is about 30 tiles per 32-atom block at a 0.9 nm cutoff, so about 120 bytes per atom. That puts a 2 GiB cap at roughly 17M atoms. FAH's first core28 HIP project had 7.9M atoms (reported, fah-core-requirements note). So a 2 GiB cap on the Ultra would bite only above about 15M atoms, and a larger cap never would in practice.

Benchmark:
1. Query both limits on the M3 Ultra with no lease needed. Metal: `xcrun swift -e 'import Metal; let d = MTLCreateSystemDefaultDevice()!; print(d.maxBufferLength, d.recommendedMaxWorkingSetSize)'`. OpenCL: extend lab 025's `clfp64.c` to print CL_DEVICE_MAX_MEM_ALLOC_SIZE and CL_DEVICE_GLOBAL_MEM_SIZE.
2. Only if the OpenCL cap is 4 GiB or less, tile a pre-equilibrated TIP3P box with numpy to 8M, 16M and 32M atoms (PME, 0.9 nm cutoff, rigid water) and run 50 steps on each platform. Record whether it runs, the peak RSS, and ns/day.

If the cap is 8 GiB or more, drop this candidate.

## 4. PME-dominated settings

Mechanism:
- Lab 011. On the M3 Ultra, charge spreading with Apple9 float atomics took 0.169 ms against 0.432 ms for fixed point.
- Verified. OpenCL 1.2 on Apple has no float atomic extension (lab 025 extension list), so OpenCL must spread in fixed point.
- Verified. OpenCL's PME stream is NVIDIA-only (`OpenCLKernels.cpp:53`), while Metal can add a PME queue.
- Inference. Shrinking the direct-space cutoff moves work into the reciprocal-space pipeline, which widens both of these gaps.

Benchmark, after levers 1 and 2 land: `benchmark.py --test apoa1pme,apoa1ljpme --pme-cutoff 0.7` and `--pme-cutoff 0.9` on Metal single against OpenCL single. The expected ratio at 0.7 is 1.3 to 1.6x (inference). This isn't a 2x candidate on its own.

## 5. AMOEBA

- Verified. Metal has no AMOEBA, Drude or RPMD platform code at 6df2b8bcb (`plugins/amoeba/platforms/` has common, cuda, hip, opencl and reference only). RULES.md lists amoebagk and amoebapme "once Metal has AMOEBA".
- Verified. Every DIIS iteration downloads the error array and waits on an event before the host decides whether it has converged (`plugins/amoeba/platforms/common/src/AmoebaCommonKernels.cpp:1313-1339`). benchmark.py uses mutual polarization with epsilon 1e-5, so expect about 10 or more syncs per step (inference).
- Inference. The sync savings from section 2 apply per iteration. But AMOEBA's per-step GPU work is milliseconds, so single precision lands at 1.1 to 1.3x. The larger win is mixed, which Tinker-OpenMM users commonly run (inference). OpenCL can't do that at all, so it falls back to the CPU, as in section 1.

Benchmark, once the plugins lane lands AMOEBA: `benchmark.py --test amoebapme,amoebagk` with Metal single against OpenCL single, and Metal mixed against `--platform CPU`.

## 6. Custom forces with heavy expressions

- Verified. Metal maps EXP to `__expf` and LOG to `__logf`, both fast intrinsics (`MetalContext.cpp:209-210`). OpenCL uses `native_exp` and `native_log` only if a device accuracy test passes a 1e-6 relative error; otherwise it uses precise `exp` and `log` (`OpenCLContext.cpp:365-395`). POW, SIN, COS, ERFC and the rest are precise library calls on both.
- Lab 008. Apple's OpenCL and Metal math libraries differ in the last bits for sin and cos, so they are different implementations of the same functions.
- Inference. The gap shows up only in expressions dominated by exp or log, and only if OpenCL failed the native test. Expect 1.0 to 1.3x.

Benchmark: DHFR implicit with `implicitSolvent=app.GBn2` (a CustomGBForce), plus a 50k-atom water box with a CustomNonbondedForce exp-6 potential, `A*exp(-B*r)-C/r^6`. Run both in single precision on both platforms. Log which EXP define OpenCL picked by running with `OPENMM_SAVE_TEMPS` or printing the program source.

## 7. Several simulations sharing the GPU

- Verified. OpenCL gives each process its own MTLCommandQueue and one serial encoder per flush (renderer disassembly). I found no global lock or serialization in the renderer beyond a per-queue `os_unfair_lock`.
- Inference. Several processes fill each other's dispatch gaps on both platforms, which shrinks Metal's per-dispatch GPU edge (1.88 against 2.27 us in lab 008). Expect 1.0 to 1.1x.

Benchmark: 1, 2, 4 and 8 concurrent `benchmark.py --test gbsa --seconds 30` processes per platform, summing ns/day. It's cheap, so run it to close the question.

## 8. Context creation and compile time

- Verified. Both platforms compile generated source at context creation. Metal calls `newLibraryWithSource`, and OpenCL builds its program on the renderer through `gldBuildComputeProgram`. I found no on-disk kernel cache in `MetalContext::createModule` (`MetalContext.cpp:400-470`).
- Inference. Short jobs that create many contexts are dominated by compile time, for example lambda windows, FAH work-unit starts and test suites. Whichever compiler or cache is faster wins by a large factor there, and I can't predict which.

Benchmark: time `Context(...)` creation for amber20-dhfr and apoa1pme, 5 cold runs in fresh processes and 5 warm runs, on both platforms.

## Things I checked that are not OpenCL weaknesses

- 64-bit force accumulation. OpenCL on Apple uses the same split-word 32-bit emulation as Metal (`platforms/opencl/src/kernels/common.cl:7-23`), so they don't differ there.
- Silent CPU fallback. Lab 025 enumerated a single device, "Apple M3 Ultra", on platform 0. OpenCL.framework ships `libCLVMCPUPlugin.dylib`, but I found no path where OpenMM picks it over the GPU. Nothing here suggests OpenMM silently falls back to the CPU.

## Adjacent finding: a Metal weakness

- Verified. `MetalContext::getSupports64BitGlobalAtomics()` returns false (`MetalContext.h:347-349`). So `CommonMinimizeKernel` sets `singleBlockReductions = mixedIsDouble && !supports64BitGlobalAtomics` (`platforms/common/src/CommonMinimizeKernel.cpp:86`), which means energy minimization in Metal mixed reduces in a single thread block. Minimizing large systems in mixed may be slow on Metal. Time `LocalEnergyMinimizer` on apoa1pme in Metal mixed before anyone claims a mixed-precision workflow win that includes minimization.

## Sources

- Code, all under `/Users/amir/code/mini/hipdelta-gbsa/`:
  - `platforms/opencl/src/OpenCLContext.cpp:213-216,365-412`
  - `platforms/opencl/src/OpenCLKernels.cpp:53`
  - `platforms/opencl/src/OpenCLNonbondedUtilities.cpp:276-283,412`
  - `platforms/opencl/src/kernels/common.cl:7-23`
  - `platforms/metal/src/MetalContext.cpp:206-219`
  - `platforms/metal/include/MetalContext.h:347`
  - `platforms/metal/src/MetalPlatform.cpp:154`
  - `platforms/metal/src/MetalEvent.cpp:55`
  - `platforms/common/src/CommonIntegrateCustomStepKernel.cpp:744-776`
  - `platforms/common/src/CommonMinimizeKernel.cpp:86`
  - `plugins/amoeba/platforms/common/src/AmoebaCommonKernels.cpp:1313-1339`
- Binary: `/System/Library/Extensions/AppleMetalOpenGLRenderer.bundle/Contents/MacOS/AppleMetalOpenGLRenderer`. The disassembly is saved at `/private/tmp/claude-501/-Users-amir/2071129c-c6c2-47ff-a8dd-5b2d8f1554ee/scratchpad/rb/gl_dis.txt`.
- Lab: experiments 001, 008, 011, 024 and 025; research notes `2026-09-24-fah-precision.md` and `2026-09-23-fah-core-requirements.md`.
- Web: [FAH forum t=43406, Apple M1-M4 clinfo](https://forum.foldingathome.org/viewtopic.php?t=43406); [MTLDevice.maxBufferLength](https://developer.apple.com/documentation/metal/mtldevice/maxbufferlength).

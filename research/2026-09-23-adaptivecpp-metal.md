# AdaptiveCpp Metal vs native Metal for OpenMM

Research for the reply to bdenhollander on [openmm/openmm#5397](https://github.com/openmm/openmm/issues/5397) (2026-09-23T01:04Z). Read-only; nothing posted. All sources fetched 2026-09-23.

## Summary (10 lines)

1. The MR bdenhollander linked, [GROMACS !6137](https://gitlab.com/gromacs/gromacs/-/merge_requests/6137), is a *native* Metal backend. GROMACS closed it unmerged on 2026-09-08 in favour of SYCL through AdaptiveCpp.
2. GROMACS's reason was cost, not speed: they already ship a SYCL backend, so AdaptiveCpp's Metal target gives them Apple GPUs with no new kernels. The native MR won only on small systems, and OpenCL beat both there.
3. AdaptiveCpp's Metal backend is experimental and unreleased. It landed on `develop` on 2026-02-26, after the last release (v25.10.0, Nov 2025). It needs macOS 26.
4. Its flow is SSCP: SYCL to LLVM IR at build time, then LLVM IR to MSL *source* at runtime, compiled by `newLibrary`. It does not emit AIR.
5. It supports USM, local memory, 32-bit and f32 atomics, and SIMD shuffles, reductions, scans and any/all. It has no 64-bit atomics, no `double` (soft-double is only planned), no ballot, and it leaves Metal's default Relaxed math mode on.
6. Main blocker for OpenMM: Common Compute builds kernel source at runtime (59 `compileProgram` calls in 14 files, plus user expressions from custom forces and integrators). AdaptiveCpp has no path for compiling source at runtime.
7. So a SYCL port would not be "a new ComputeContext". It would mean rewriting the Common kernel layer (67 files, about 12.1k lines) into single-source C++ and finding a replacement for runtime codegen.
8. Intel: OpenMM's OpenCL platform already accepts Intel GPUs. It runs them with `simdWidth = 1` and no tuning, so tuning that path is the cheaper Intel win. GROMACS itself recommends DPC++ for Intel, not AdaptiveCpp.
9. Our native Metal platform keeps the Common kernels unchanged (67 lines touched in `platforms/common`). It runs 0.99 to 1.07x OpenCL on benchmark.py and 1.20 to 1.28x on FAHBench dhfr, and adds df64 mixed precision.
10. Recommendation: stay native Metal. Revisit AdaptiveCpp only if OpenMM adopts SYCL for other reasons.

## Draft reply

> Thanks, that's a useful pointer. The MR you linked is actually GROMACS's native Metal backend, which they closed because they already ship a SYCL backend, so AdaptiveCpp gives them Apple GPUs without new kernels. OpenMM is in the opposite spot: Common Compute generates kernel source at runtime for custom forces and integrators, and AdaptiveCpp compiles kernels ahead of time. It also has no 64-bit atomics or fp64 on Metal yet. Native Metal runs the Common kernels unchanged, already matches OpenCL on benchmark.py and is 20 to 28% faster on FAHBench dhfr, and adds mixed precision. For Intel GPUs, the OpenCL platform already runs there without any Intel-specific tuning, so we'd get more from tuning that path.

---

## 1. State of AdaptiveCpp's Metal backend

**Status: experimental and unreleased.** Verified.
- The doc says: "The Metal backend is experimental. It is under active development, and not all SYCL features are supported yet. Expect rough edges." ([install-metal.md:3](https://github.com/AdaptiveCpp/AdaptiveCpp/blob/d39e7e71c7c1b2c96bafa58693412d4e1c526b24/doc/install-metal.md?plain=1#L3))
- It was added in [PR #1961](https://github.com/AdaptiveCpp/AdaptiveCpp/pull/1961) (commit 94e17498, 2026-02-26). The latest release is v25.10.0 (2025-11-05) (`gh api repos/AdaptiveCpp/AdaptiveCpp/releases`). Metal is therefore on `develop` only. The umbrella issue [#864](https://github.com/AdaptiveCpp/AdaptiveCpp/issues/864) (opened 2022-11-13) is still open.
- It requires macOS 26 ("other versions are unlikely to work"), Apple Silicon, metal-cpp downloaded separately, and an LLVM ≥15 build, with a 2-stage build recommended ([install-metal.md:9-13](https://github.com/AdaptiveCpp/AdaptiveCpp/blob/d39e7e71c7c1b2c96bafa58693412d4e1c526b24/doc/install-metal.md?plain=1#L9-L13)). The runtime compiles as MSL 4.0 ([metal_code_object.cpp:35](https://github.com/AdaptiveCpp/AdaptiveCpp/blob/d39e7e71c7c1b2c96bafa58693412d4e1c526b24/src/runtime/metal/metal_code_object.cpp#L35)). Our platform compiles as MSL 3.1, which means macOS 14 (`/Users/amir/code/mini/openmm-metal/platforms/metal/src/MetalContext.cpp:489`).
- Activity is high. There are 38 Metal commits since February, mostly by Alexey Ozeritskiy, plus Andrey Alekseenko (al42and, the GROMACS reviewer) and Anudit Nagar (the author of !6137) (`git log --grep=metal` on the clone at d39e7e71).

**Compilation flow: generic SSCP, LLVM IR to MSL source at runtime.** Verified.
- "AdaptiveCpp compiles SYCL kernels to LLVM IR at compile time, then translates that IR to Metal Shading Language (MSL) at runtime" ([install-metal.md:5](https://github.com/AdaptiveCpp/AdaptiveCpp/blob/d39e7e71c7c1b2c96bafa58693412d4e1c526b24/doc/install-metal.md?plain=1#L5)).
- The translator structurizes the LLVM CFG into loop/if/sequence trees and prints MSL. Integers are stored unsigned and all pointers as `void*` with casts at use sites (PR #1961 description; `src/compiler/llvm-to-backend/metal/Emitter.cpp`, `HLExtractionPass.cpp`).
- The runtime hands the MSL string to `device->newLibrary(source, options)` with `LanguageVersion4_0` and `LibraryOptimizationLevelSize` ([metal_code_object.cpp:35-41](https://github.com/AdaptiveCpp/AdaptiveCpp/blob/d39e7e71c7c1b2c96bafa58693412d4e1c526b24/src/runtime/metal/metal_code_object.cpp#L35-L41)). There is no AIR or metallib path.
- It never sets `mathMode`, so Apple's default applies: `MTLMathModeRelaxed`, "the default for Apple silicon devices" ([Apple docs](https://developer.apple.com/documentation/metal/mtlmathmode/relaxed)). Our platform sets `MathModeSafe` plus precise functions (`MetalContext.cpp:490-491`). That was needed to match OpenCL bit for bit (RedesignedRobot, #5397, 2026-09-21).
- Inference: the optimize-for-size level may cost some kernel speed. Not measured.

**Feature support.** Verified from docs and source at d39e7e71.

| Feature | Status | Evidence |
|---|---|---|
| USM | Supported. Allocations are made resident via `MTLResidencySet`; the old doc limitation was removed | [install-metal.md:58](https://github.com/AdaptiveCpp/AdaptiveCpp/blob/d39e7e71c7c1b2c96bafa58693412d4e1c526b24/doc/install-metal.md?plain=1#L58), commits 07f70113 (#2091), 5480cb24 |
| 64-bit integer atomics | **Not supported** | [install-metal.md:112](https://github.com/AdaptiveCpp/AdaptiveCpp/blob/d39e7e71c7c1b2c96bafa58693412d4e1c526b24/doc/install-metal.md?plain=1#L112). [atomic.cpp:19-56](https://github.com/AdaptiveCpp/AdaptiveCpp/blob/d39e7e71c7c1b2c96bafa58693412d4e1c526b24/src/libkernel/sscp/metal/atomic.cpp#L19-L56) declares only i8/i16/i32/u8/u16/u32/f32 |
| fp64 | **Not supported**. The compiler errors on `double` ([Emitter.cpp:1524-1525](https://github.com/AdaptiveCpp/AdaptiveCpp/blob/d39e7e71c7c1b2c96bafa58693412d4e1c526b24/src/compiler/llvm-to-backend/metal/Emitter.cpp#L1524-L1525)). IEEE soft-double is "planned for a future release" | [install-metal.md:110](https://github.com/AdaptiveCpp/AdaptiveCpp/blob/d39e7e71c7c1b2c96bafa58693412d4e1c526b24/doc/install-metal.md?plain=1#L110) |
| float atomics | f32 fetch-add, including on local memory | atomic.cpp:56, commit 80ab1994 (#2002) |
| Subgroups / SIMD-group | Shuffle up/down/xor/index, `simd_sum/min/max/and/or/xor`, scans, any/all. Subgroup size and lane ID come from `[[threads_per_simdgroup]]`/`[[thread_index_in_simdgroup]]` | [shuffle_helpers.hpp:43-79](https://github.com/AdaptiveCpp/AdaptiveCpp/blob/d39e7e71c7c1b2c96bafa58693412d4e1c526b24/src/libkernel/sscp/metal/shuffle_helpers.hpp#L43-L79), [reduction.cpp:62-78](https://github.com/AdaptiveCpp/AdaptiveCpp/blob/d39e7e71c7c1b2c96bafa58693412d4e1c526b24/src/libkernel/sscp/metal/reduction.cpp#L62-L78), [collpredicate.cpp:26-36](https://github.com/AdaptiveCpp/AdaptiveCpp/blob/d39e7e71c7c1b2c96bafa58693412d4e1c526b24/src/libkernel/sscp/metal/collpredicate.cpp#L26-L36), [Emitter.cpp:231-233](https://github.com/AdaptiveCpp/AdaptiveCpp/blob/d39e7e71c7c1b2c96bafa58693412d4e1c526b24/src/compiler/llvm-to-backend/metal/Emitter.cpp#L231-L233) |
| Ballot | No `simd_ballot` anywhere in `src/libkernel/sscp/metal/` (grep, zero hits) | This matters because ballot is the 2.3 to 3.1x `findBlocksWithInteractions` win measured in #5397 |
| Local memory | Dynamic local memory via program-scope globals | [localmem.cpp:21-29](https://github.com/AdaptiveCpp/AdaptiveCpp/blob/d39e7e71c7c1b2c96bafa58693412d4e1c526b24/src/libkernel/sscp/metal/localmem.cpp#L21-L29), commit df1771a5 (#2043) |
| printf / `sycl::stream` | Not supported | install-metal.md:116 |
| Event cost | Every SYCL event forces its own command-buffer commit. The coarse-grained events extension avoids this | [install-metal.md:114](https://github.com/AdaptiveCpp/AdaptiveCpp/blob/d39e7e71c7c1b2c96bafa58693412d4e1c526b24/doc/install-metal.md?plain=1#L114) |

**Published performance.** Verified that these numbers are published. I did not reproduce any of them.
- **al42and's sweep** (M4 Pro, ACpp develop b9c4c847, Clang 21, median ns/day, Grappa set, sizes in thousands of atoms) comes from the [spreadsheet](https://docs.google.com/spreadsheets/d/1ROZ7EhysO2xy9maeiHSHf66OSFI-Z_FMIULaKni4brI/edit) linked in !6137. It predates the batching fix below.

  | PME size | ACpp (nb+pme GPU) | ACpp GPU-resident | native !6137 | OpenCL |
  |---|---|---|---|---|
  | 3k | 216.4 | 217.1 | 280.8 | **340.9** |
  | 24k | 137.5 | **178.1** | 156.7 | 172.5 |
  | 96k | 66.6 | **83.7** | 63.9 | 63.1 |
  | 768k | 12.2 | **14.0** | 9.5 | 7.3 |
  | 6144k | 1.5 | **1.7** | 1.2 | 1.0 |

  RF follows the same pattern: OpenCL leads at 3k to 6k, and ACpp GPU-resident leads from 12k up.
- **[ACpp PR #2196](https://github.com/AdaptiveCpp/AdaptiveCpp/pull/2196)** (merged 2026-09-18, by Anudit Nagar) batches command buffers. Before it, ACpp committed about 11 command buffers per MD step against about 3.5 for native Metal, and "the GPU was idle 25-40% of each step". GROMACS GPU-resident on an M2 Max gained +71% (RF) and +84% (PME) at 96k atoms, +14 to 47% at 192k to 384k, and +3 to 8% at 768k.
- **[GROMACS !6161](https://gitlab.com/gromacs/gromacs/-/merge_requests/6161)** (open) adds VkFFT-on-Metal through ACpp interop. PME on an M2 Max, GPU-resident, gained +60% to +142% (6.1M atoms: 0.59 to 1.16 ns/day).
- Third-party ([warpx-metal](https://github.com/Lulzx/warpx-metal), reported): the GPU is behind a 12-thread CPU on small grids because "per-step launch overhead dominates". Software fp64 costs about 13x fp32. They replaced 64-bit atomic sorting with multipass scans.

## 2. GROMACS !6137 and what GROMACS gave up

Verified from the [MR API](https://gitlab.com/api/v4/projects/gromacs%2Fgromacs/merge_requests/6137) and its public `discussions.json`.
- **!6137** is titled "Add a native Apple Metal GPU backend", by anudit, opened 2026-08-08, **closed unmerged 2026-09-08**. It ran PME and nonbonded on-device with vendored VkFFT (`VKFFT_BACKEND=5`). The author's numbers (98k SPC/E water): Metal 32.79 ns/day vs OpenCL 28.83. At 1.0M atoms: Metal 4.36 vs OpenCL 2.61.
- **al42and (GROMACS core dev), 2026-08-17:** "The current plan (see #2548) is to use SYCL for targeting AppleSilicon GPUs via AdaptiveCpp's Metal backend instead of introducing (and maintaining) yet another explicit GPU layer." On his M4 Pro sweep, the native MR "typically performs worse than SYCL". "For very small systems (<=48k atoms PME, <=6k atoms RF), this MR performs better than SYCL/ACpp, but both are behind OpenCL." Also: "both OpenCL and SYCL kernels in GROMACS have zero optimizations specifically for Apple GPUs."
- The author then split the work: the SYCL-side fixes went to !6161, and command-buffer batching and residency went upstream into ACpp (#2196).

What GROMACS gave up or worked around:
- **Small-system speed.** They accept ACpp trailing both OpenCL and native Metal below about 48k atoms (PME). al42and blames launch latency and expects "more work on the AdaptiveCpp side" (!6137). Batching (#2196) has since narrowed this. I found no post-#2196 small-system numbers.
- **FFT.** SYCL on Apple had no GPU FFT path at all, so PME FFT ran on the CPU until !6161 added a VkFFT Metal backend through `sycl::backend::metal` interop.
- **Dispatch overhead.** It was fixed inside ACpp (#2196), not in GROMACS.
- **Transfers.** A shared-USM option measured +0.7 to 2.8%. al42and asked to drop it from !6161.
- **fp64 and 64-bit atomics.** These cost GROMACS nothing, because its GPU kernels are single precision and accumulate forces with float atomics. That is inference from GROMACS's design; I did not re-read its kernels for this report. OpenMM depends on both.
- **Context.** GROMACS already treats SYCL as its main portable backend. It recommends DPC++ for Intel and ACpp for AMD, and marks OpenCL deprecated but "currently the only backend supporting Apple M-series GPUs" ([GROMACS 2026.3 install guide](https://manual.gromacs.org/current/install-guide/index.html)). For them, Metal via ACpp adds no new kernels. That asymmetry decides the question.
- GROMACS #2548 ("Use metal for GPU acceleration in macOS", 2018) was closed in 2018 per its Redmine import. al42and still cites it as the plan of record.

## 3. What AdaptiveCpp would mean for OpenMM

**It would not be a new ComputeContext.** Verified facts, inference on effort.
- The Common Compute contract is `ComputeContext::compileProgram(const std::string source, defines)`, which compiles a source string at runtime ([ComputeContext.h:195](https://github.com/openmm/openmm/blob/3c9effc96d0c89cc7bfc8154eb9122a618061d8f/platforms/common/include/openmm/common/ComputeContext.h#L195)).
- There are 59 `compileProgram(` call sites across 14 files in `platforms/common/src/*.cpp`. The kernel bodies are 67 files and about 12.1k lines in `platforms/common/src/kernels/` (local count at merge-base 3c9effc96).
- User expressions become kernel code at runtime. For example, `CommonCalcCustomNonbondedForceKernel` calls `ExpressionUtilities::createExpressions`, splices the result into the template, and compiles it ([CommonCalcCustomNonbondedForceKernel.cpp:278, 290, 348](https://github.com/openmm/openmm/blob/3c9effc96d0c89cc7bfc8154eb9122a618061d8f/platforms/common/src/CommonCalcCustomNonbondedForceKernel.cpp#L278)). peastman said the same about bonded forces: "The kernel code just gets generated and compiled at runtime" ([#3405](https://github.com/openmm/openmm/issues/3405), 2022-02-11).
- SYCL under ACpp compiles kernels ahead of time from C++ lambdas. ACpp's extension list ([doc/extensions.md](https://github.com/AdaptiveCpp/AdaptiveCpp/blob/d39e7e71c7c1b2c96bafa58693412d4e1c526b24/doc/extensions.md)) has no source-compilation extension. The closest is `ACPP_EXT_DYNAMIC_FUNCTIONS`, which swaps in *precompiled* `SYCL_EXTERNAL` functions at JIT time. It cannot compile an arbitrary user expression.
- The only SYCL runtime-source path I found is DPC++'s experimental [`sycl_ext_oneapi_kernel_compiler`](https://github.com/intel/llvm/blob/sycl/sycl/doc/extensions/experimental/sycl_ext_oneapi_kernel_compiler.asciidoc). It targets Intel GPUs and CPUs, not Metal.

So OpenMM would need one of three paths:
- (a) Rewrite every Common kernel as SYCL C++ and replace runtime codegen with an on-device expression interpreter. That would be slow.
- (b) Precompile a fixed menu of functions.
- (c) Use ACpp's Metal interop (`AdaptiveCpp_enqueue_custom_operation` plus `get_native_queue`) to launch MSL we compile ourselves. That is native Metal again with an extra layer.

Inference on effort: a SYCL platform means rewriting the shared kernel layer, not adding a platform beside it. peastman's estimate for a Common Compute Metal platform was "1-2 months" (#5397, 2026-09-09). A SYCL rewrite is a larger class of project. It would also split CUDA, OpenCL and HIP from SYCL, which cuts against the "90% shared" design peastman cites (#5397, 2026-09-10).

**What else OpenMM would inherit today:**
- No 64-bit atomics. We would reimplement split-word fixed-point accumulation in SYCL, as we already do in MSL.
- No fp64. We would reimplement df64 in SYCL. That is doable, since it is plain float math.
- No ballot.
- Relaxed math with no knob.
- A macOS 26 floor.
- An LLVM plus metal-cpp toolchain on every build machine. conda-forge packaging would need ACpp built with the Metal backend. I have not verified whether conda-forge ships one; I did not check.

For comparison, our native platform is about 4.5k host lines plus 1.9k lines of `.metal` kernels, and touched 67 lines in `platforms/common` (git diff 3c9effc96..metal, local repo `/Users/amir/code/mini/openmm-metal`).

## 4. The Intel GPU angle

- **The OpenCL platform already covers Intel.** Verified. `isSupported()` accepts vendor "Intel" ([OpenCLContext.cpp:78-84](https://github.com/openmm/openmm/blob/3c9effc96d0c89cc7bfc8154eb9122a618061d8f/platforms/opencl/src/OpenCLContext.cpp#L78-L84)).
  - Intel gets no optimization flags ([:209-212](https://github.com/openmm/openmm/blob/3c9effc96d0c89cc7bfc8154eb9122a618061d8f/platforms/opencl/src/OpenCLContext.cpp#L209-L212)).
  - It falls to the generic `simdWidth = 1` branch ([:288-290](https://github.com/openmm/openmm/blob/3c9effc96d0c89cc7bfc8154eb9122a618061d8f/platforms/opencl/src/OpenCLContext.cpp#L288-L290)), which disables the warp-synchronous kernel paths.
  - In the field: it works on Xe Max and Gen9 ([#3405](https://github.com/openmm/openmm/issues/3405)). There were test failures on Data Center GPU Max 1550 ([#4689](https://github.com/openmm/openmm/issues/4689), closed).
- **What AdaptiveCpp would add.** Inference: ACpp reaches Intel GPUs through Level Zero or OpenCL SPIR-V, into the same Intel graphics compiler that Intel's OpenCL uses. Any gain would come from subgroup-aware kernels, not from ACpp itself. OpenMM can get those inside the OpenCL platform by setting a real SIMD width for Intel and using `cl_intel_subgroups`/`cl_khr_subgroups`. That is a far smaller change than a SYCL port. I did not verify which subgroup extensions current Intel drivers expose.
- GROMACS, the example cited, recommends Intel oneAPI DPC++ for Intel GPUs, not AdaptiveCpp ([install guide](https://manual.gromacs.org/current/install-guide/index.html)). Reported.

## 5. Recommendation

**Native Metal. Don't pursue AdaptiveCpp for OpenMM now. Treat Intel as OpenCL tuning.**

Strongest honest case for AdaptiveCpp:
- One SYCL codebase could reach Apple (Metal), Intel (Level Zero), AMD, NVIDIA, and Vulkan through ACpp's experimental `vk` backend (`doc/install-vulkan.md`).
- It avoids a fifth hand-maintained platform.
- Apple-specific runtime fixes land upstream and benefit GROMACS, WarpX and others. Batching (#2196) is proof that this happens quickly.
- GROMACS data shows ACpp GPU-resident beating a first-cut native Metal port from about 24k atoms up.
- A GROMACS core dev (al42and) is actively co-maintaining ACpp's Metal backend.

Strongest honest case for native Metal:
- It fits Common Compute unchanged, including runtime codegen for every Custom* force and CustomIntegrator. ACpp has no answer for that.
- It already exists: about 108/110 ctest on three chips, 0.99 to 1.07x OpenCL on benchmark.py, 1.20 to 1.28x on dhfr, and df64 mixed precision that Apple's OpenCL cannot run (#5397, RedesignedRobot 2026-09-23).
- It gives direct control over the things that decided accuracy and speed in our measurements: math mode, command-buffer batching, and `simd_ballot`. ACpp lacks a ballot builtin and a math-mode setting today.
- It needs only the Command Line Tools and runs on macOS 14 and later, versus ACpp's macOS 26 and a custom LLVM toolchain.
- ACpp's weak regime, small systems where launch latency dominates, is where many OpenMM and Folding@home workloads live. That is inference from typical system sizes; FAHBench dhfr is 23.5k atoms.

Both: not worth it. Running both would double the Apple surface without solving runtime codegen on the SYCL side. Revisit only if OpenMM adopts SYCL for Intel or AMD on its own merits.

## Caveats

- I did not run AdaptiveCpp or GROMACS. All ACpp and GROMACS performance numbers are theirs.
- The spreadsheet data predates ACpp #2196 batching, so small-system ACpp numbers are likely better now. Unmeasured.
- GitLab notes for !6137 and !6161 came from the public `discussions.json` web endpoint. The v4 notes API returned 401.
- Our own performance numbers are as given in the task brief and RedesignedRobot's #5397 posts. I did not re-run them. No GPU work was done on this laptop.
- "No ballot" and "no runtime source compilation" are absence claims: grep of `src/libkernel/sscp/metal/` and the extension list at d39e7e71. A newer commit could change either.

## Pointers

- [AdaptiveCpp `doc/install-metal.md`](https://github.com/AdaptiveCpp/AdaptiveCpp/blob/develop/doc/install-metal.md): the authoritative limitation list; watch it for soft-double and atomic64.
- [GROMACS !6137 discussion](https://gitlab.com/gromacs/gromacs/-/merge_requests/6137): al42and's full reasoning and the spreadsheet link.
- [ACpp PR #2196](https://github.com/AdaptiveCpp/AdaptiveCpp/pull/2196): the command-buffer batching design. It parallels our one-open-encoder approach and makes a useful cross-check.
- `platforms/opencl/src/OpenCLContext.cpp:200-300` (local or upstream): where Intel tuning would go.
- `platforms/common/src/ExpressionUtilities.cpp` and the Custom* kernels: the runtime-codegen dependency that rules out SYCL.

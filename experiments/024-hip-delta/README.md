# 024: Metal as the smallest diff from HIP

peastman plans to write the Metal platform himself, starting from CUDA or HIP, and to read ours as a reference. So the product here is a readable "HIP to Metal in N lines" diff. Every line that differs from HIP should exist because Metal needs it or because it measurably speeds things up.

The OpenMM branch is `metal-hipdelta` on the `mini` remote, from merge base 3c9effc96. The comparison build is `metal` at 361452c5c. Stage 2 is commits 495350e28 (HIP's nonbonded kernels), 24c34d794 (tuning), aa7464387 (a destructor fix from review) and 1e90e5b0a (the cut to the minimum: no added comments, no defensive code HIP lacks). 62e1e2e95 applies the verifier's review. Stage 3 (measured speedups) and stage 4 (mixed precision) are in progress.

## Metric

`delta.sh <repo> [ref]` copies `platforms/hip`, renames Hip to Metal and `.hip` to `.metal`, and counts the lines `diff -w` adds in each shared file of `src`, `src/kernels` and `include`. Removed lines never count: 62e1e2e95 also removes 942 lines of HIP from those files. It lists files that exist only in Metal, and HIP files with no Metal counterpart. Those are MetalParallelKernels.h (160 lines), MetalParallelKernels.cpp (307) and parallel.metal (13), HIP's multi-device support, which Metal drops. Its last line counts all of `platforms/metal` the same way, CMake files and tests included.

| Build | Added lines in shared files | Metal-only lines | Total |
|---|---:|---:|---:|
| `metal` 361452c5c (baseline) | 2,024 | 697 (df64 683, utilities 14) | 2,721 |
| Stage 1: host layer, `metal` nonbonded kept | 1,340 | 0 | 1,340 |
| Stage 2: HIP nonbonded and neighbor list kernels, 495350e28 | 716 | 0 | 716 |
| Stage 2 plus tuning, 24c34d794 | 723 | 0 | 723 |
| Stage 2 plus the destructor fix, aa7464387 | 731 | 0 | 731 |
| Stage 2 cut to the minimum, 1e90e5b0a | 467 | 0 | 467 |
| Verifier fixes, 62e1e2e95 | 464 | 0 | 464 |

The table's count leaves out code a reader has to write too:

- All of `platforms/metal`, CMake files and tests included, adds 995 lines at 62e1e2e95 (1,262 at aa7464387). The tests are most of the difference: 249 lines added to HIP's test files and 257 in Metal-only tests (TestMetalCommandBatching, TestMetalFFT).
- Outside `platforms/metal` the branch changes 13 files, +100 and -45 lines, most of it shared with `metal`: the top-level CMakeLists.txt (12), the common kernels dpd, gayBerne and minimize and ExpressionUtilities.cpp (24), a `PRIVATE` macro in the CUDA, HIP and OpenCL common kernels (3), the vkFFT.h Metal backend patch (+10 -28, with a 12-line note), TestCheckpoints.h and TestCustomIntegrator.h (33), and the developer guide (6).
- The `PRIVATE` line in `platforms/hip/src/kernels/common.hip` means delta.sh diffs against a HIP that is 1 line modified.
- metal-cpp is vendored: 35,021 lines in 127 files.

Without df64 the baseline is 2,038. Stage 2 is single precision only, so it has no mixed precision to compare with df64. Logs: `results/delta-*.txt`.

## Delta per file at HEAD

The source carries no comments beyond what HIP's files already have, including their license headers. Every reason lives here instead.

| File | Added | Why |
|---|---:|---|
| src/MetalContext.cpp | 119 | Kernel signature rewriter, 42 lines. MSL wants `device` on pointer parameters and takes scalar and vector arguments only by `constant` reference, so a value parameter becomes `constant T& _in_x` plus a copy `T x = _in_x;` at the top of the body. Preprocessor lines inside a parameter list are copied into that prologue too. Two `regex_replace` calls rename `thread`, which MSL reserves and the common kernels use as a variable name, and turn `long long` into `long`, which MSL lacks. Compile, 15 lines: `metal_stdlib` header, MSL 3.2, safe math with precise functions. getKernel, 19 lines: pipeline reflection records the byte size of each `_in_` argument. Launch, 13 lines: `setBytes` for those, `setBuffer` for the rest, into the queue's open encoder. Device, queue and properties, 16 lines, including the GPU core count from the IORegistry, which Metal doesn't report. Host memory and releases, 8 lines. Tuning, 2 lines: 12 thread blocks per core and RECIP as `fast::divide`. |
| src/kernels/common.metal | 105 | CUDA names for MSL built-ins (program-scope `threadIdx` and friends, `__syncthreads`, `__threadfence`, `__shared__`), atomics (the M1 and M2 have no 64 bit atomic add, and MSL has no float atomic min or max), the `make_` names the kernels use, `f` suffix math names, erf and erfc (MSL has neither), `__float2half_ru`, realToFixedPoint without `long long`. HIP's `__expf` and `__logf` are its fast intrinsics and map to `fast::exp` and `fast::log`. `__fsqrt_rn` maps to `precise::sqrt`. HIP's `__frsqrt_rn` rounds to nearest, so mapping it to `fast::rsqrt` is not a match: it is a speed choice from the tuning table below. `MEM_FENCE` is empty: HIP's hot bonded kernels call it, and a device fence there costs time for ordering that the kernels don't need within a SIMD group. `SYNC_WARPS` is `simdgroup_barrier`. |
| src/MetalQueue.cpp | 60 | One open command buffer and compute encoder per queue. Commits happen at upload, download, event and step boundaries. Committed buffers wait in a deque and are released once complete, and a failed buffer throws at the next commit or finish. The lock is recursive because CustomCPPForce uploads from a worker thread. Autorelease pools wrap the metal-cpp calls that return autoreleased objects, since Python threads have no pool. |
| include/MetalQueue.h | 21 | Declarations for the above, and the `metalStream_t` typedef. `getCommitCount` and its counter, 5 lines, exist for TestMetalCommandBatching. Metal reports no count of committed command buffers, and no other API shows whether a step went out as one buffer or many. Batching is what the no-commit variant below lost 4 to 23 percent to, so the test guards it and the lines stay. |
| src/MetalPlatform.cpp | 21 | macOS 15 and GPU family Apple7 check, device name through an autorelease pool (metal-cpp returns an autoreleased string), one device, PME stream off by default. That default is measured: on HEAD with it true, pme ran 208.0 and 208.5 ns/day against 183.7 and 183.4 with it false, and apoa1pme 54.2 and 54.3 against 51.9 and 52.1 (verifier, M2, host clock, 2 rounds of 20 s). Each event between the two queues commits a command buffer, which is where the time goes. A second context throws: with `DeviceIndex` "0,0" two contexts on the one GPU returned 0 kJ/mol for a bond whose energy is 0.5. |
| src/MetalArray.cpp | 17 | Shared storage buffers of at least 16 bytes (Metal can't create empty buffers). Upload and download finish the queue and then memcpy. copyTo is a blit in the open command buffer. |
| src/MetalEvent.cpp | 17 | MTLSharedEvent signal and wait. A failed buffer is reported by the queue's next commit, not by the event. |
| src/MetalFFT3D.cpp | 17 | VkFFT's Metal backend. vkFFT.h compiles the metal-cpp implementation into the file that includes it, so only this file includes it, and the header forward-declares a wrapper struct. VkFFT compiles with fast math, so `useLUT` takes twiddle factors from a table. VkFFT's Metal backend only encodes into a given encoder, so the FFT goes into the open one. |
| include/MetalContext.h | 14 | Host vector typedefs (`int2`, `float4`, `uint1`) that HIP gets from its runtime headers, `getCurrentStream` returning the queue, the reflection map, two capability getters that return false. |
| src/kernels/findInteractingBlocks.metal | 14 | See kernel rewrites below. |
| src/kernels/intrinsics.metal | 12 | `warpSize`, `__shfl`, `__shfl_down`, `__ballot` on simd_ functions. The GB kernels shuffle 64 bit values, which `simd_shuffle` rejects, so two overloads split them into 32 bit halves. |
| src/MetalNonbondedUtilities.cpp | 10 | Shared buffer for the interaction count, ComputeEvent, a commit before waiting on the count. Tuning: 40 force thread blocks per core, one tile per batch. |
| src/kernels/sort.metal | 10 | `extern __shared__` becomes a `[[threadgroup(0)]]` parameter, `__threadfence()` before the last-block reduction, `max(0u, ...)` for MSL's stricter overloads. |
| include/MetalArray.h | 6 | `metal-cpp` include and the handle typedefs `metalDevice_t`, `metalDeviceptr_t`, `metalModule_t`, `metalFunction_t`. With them HIP's declarations stay as they are. |
| src/MetalIntegrationUtilities.cpp | 6 | CCMA's converged flag in a shared buffer, and a ComputeEvent. |
| other 7 files | 15 | Members and includes for the above, the platform name "Metal", `maxThreadgroupMemoryLength`. |
| src/kernels/nonbonded.metal | 0 | HIP's kernel compiles unchanged. |

### Removed in the cut, and why

The lead asked for no defensive code HIP doesn't have. The cut took aa7464387 from 731 added lines to 467:

- Every comment we had added, 101 lines. HIP's own comments stay, including `// METAL-TODO: This may require tuning` above `numTilesInBatch`.
- The SIMD width check in getKernel, the throw for double and mixed precision and the 8-core fallback when the IORegistry has no core count. HIP has none of these. Double and mixed precision now fail at kernel compile with "'double' is not supported in Metal".
- The NULL checks on a new MTLSharedEvent and a new command queue. HIP does check its error codes there. Neither returned NULL in any run here. If one does, the next call dereferences NULL instead of throwing an OpenMMException. That trade saves 4 lines. What happens without each check is under risks.
- The pipeline error text in getKernel's exception. The message still names the kernel.
- A hand-written word scanner (`findWord`, `replaceWord`, `isIdentifierChar`) in favor of `std::regex`.
- A separate `launchKernel`. `executeKernelFlat` holds the launch now, and `executeKernel` calls it, as in HIP.
- `getFailure` and `releaseCompleted` on the queue. Commit releases finished buffers itself.
- Unused `make_short2`, `make_short4`, `make_uint2` to `make_uint4` and `rsqrtf`.
- HIP's `getHash`, the `metalDevice_t` return type, the `metalModule_t&` parameter and the `metalDeviceptr_t` members came back, since typedefs make them free.

Three removals came back after testing: `setLanguageVersion(3_2)` (see what didn't work), the 31-argument message (TestMetalCustomNonbondedForce checked for it) and the throw for a second context (wrong energies without it, see MetalPlatform.cpp above).

### Cut after the verifier's review, 62e1e2e95

A fresh-context verifier read every hunk and listed lines that were neither needed by Metal nor measured. 62e1e2e95 takes 467 to 464:

- The 31-argument message, 2 lines. A kernel with too many arguments still fails to compile with an OpenMMException, and TestMetalCustomNonbondedForce now looks for the compiler's own text, "no 'buffer' resource location available".
- The commit after the force computation in MetalKernels.cpp, 1 line. With and without it, 3 rounds of all six tests put every ratio within 0.8 percent of each other (`results/bench-fix-postcommit`). gbsa differed by 0.7 percent, so a rerun of gbsa and pme with 5 rounds of 20 seconds followed: 414.2 against 413.9 ns/day and 208.2 against 207.9, 0.06 and 0.13 percent (`results/bench-postcommit-rerun`). That is noise, so the line went.
- The SIMD width check was already gone in 1e90e5b0a.
- `getCommitCount` stays. See include/MetalQueue.h above.

### Kernel rewrites that a macro can't express

findInteractingBlocks.metal:

- `toReal3() const device`: MSL only calls a member function on a device-memory object if the function is qualified `device`.
- `atomicMin((device real*) blockSizeRange, ...)`: MSL can't take the address of a vector element (`&v.x`).
- `PRIVATE unsigned int& interacts`: MSL references need an address space. `PRIVATE` is the common kernels' macro for `thread`, which the rewriter renames.
- `threadgroup int* buffer = ...` (4 lines): MSL pointers into threadgroup memory need the address space.
- The two `double` overloads of `collectInteractions` are deleted. MSL has no double.
- Five `SYNC_WARPS` (`simdgroup_barrier`) where lanes of one SIMD group hand data to each other through threadgroup memory: after loading the block's positions and exclusions, at the top of the block2 loop, after collecting candidate blocks, after adding atoms to the buffer and after shifting it. HIP relies on wavefront lockstep. MSL only orders threadgroup memory between threads at a barrier. A review of the stage 2 diff flagged the missing barriers. Each sits where the whole SIMD group is converged. The final benchmark includes them.

sort.metal: dynamic threadgroup memory has to be a kernel parameter, and the last-block reduction needs a device-scope fence to see other threadgroups' writes.

## Tests

ctest `-R TestMetal`, 2 jobs, 600 s timeout, on the M2 mini and on the M3 Ultra Studio.

| Build | Chip | Result |
|---|---|---|
| `metal` 361452c5c, Single | M2 | 55/55 pass |
| Stage 1, Single | M2 | 54/54 pass |
| Stage 2 untuned, Single | M2 | 54/54 pass |
| Stage 2 aa7464387, Single | M2 | 54/54 pass |
| Stage 2 minimum before the device throw came back, Single | M2 | 53/54, TestMetalCustomIntegratorSingle failed once (stochastic, see below) |
| Stage 2 minimum 1e90e5b0a, Single | M2 | 53/54, TestMetalMonteCarloBarostatSingle failed once (stochastic, see below) |
| `metal` 361452c5c, Single and Mixed | M3 Ultra | 108/110, TestMetalLocalEnergyMinimizer Single and Mixed fail (testLargeForces, #5434, experiment 021) |
| Stage 2 minimum before the device throw came back, Single | M3 Ultra | 53/54, TestMetalMonteCarloAnisotropicBarostatSingle failed once (stochastic, see below) |
| Stage 2 minimum 1e90e5b0a, Single | M3 Ultra | 54/54 pass |
| Verifier fixes 62e1e2e95, Single | M2 | 53/54, TestMetalMonteCarloAnisotropicBarostatSingle failed once (stochastic, see below) |
| Verifier fixes 62e1e2e95, Single | M3 Ultra | 54/54 pass |

The one test `metal` has and this branch doesn't is TestMetalMixedPrecisionSingle, dropped with mixed precision. Logs: `results/ctest-*.txt` (M2) and `results/studio/ctest-*.txt` (M3 Ultra).

On the M3 Ultra this branch passes TestMetalLocalEnergyMinimizer, which `metal` fails. It passed 5 of 5 repeats, and `metal` failed 5 of 5 (`results/studio/repeats-studio.txt`). HIP's nonbonded code doesn't hit the float to long wrap that experiment 021 traced.

Four of the five full runs after the fixes had one stochastic test fail, a different one each time. The fifth, M3 Ultra run min6, passed all 54. The M2 run of 62e1e2e95 failed the anisotropic barostat. Repeats failed on both trees at about the same rate, 2 of 15 here and 3 of 15 on `metal`. The other tests didn't fail again:

| Test | Failure | Repeats, minimum | Repeats, `metal` |
|---|---|---|---|
| TestMetalCustomIntegratorSingle (M2) | random mean 0.0185, 3 sigma limit 0.0173 | 5/5 pass | 5/5 pass |
| TestMetalVariableLangevinIntegratorSingle (M3 Ultra, run min4) | temperature 755 against 766 | 5/5 pass on each chip | 5/5 pass on each chip |
| TestMetalMonteCarloAnisotropicBarostatSingle (M3 Ultra, run min5) | box volume distribution | 5/5 pass (M2) | 4/5 pass (M2) |
| TestMetalMonteCarloBarostatSingle (M2, 1e90e5b0a) | expected 1.5, found 1.3472 (TestMonteCarloBarostat.h:141) | 5/5 pass | 5/5 pass |
| TestMetalMonteCarloFlexibleBarostatSingle (M2) | passed in the full run | 5/5 pass | 5/5 pass |
| TestMetalMonteCarloAnisotropicBarostatSingle (M2, 62e1e2e95) | expected 3, found 4.098 (TestMonteCarloAnisotropicBarostat.h:302) | 13/15 pass | 12/15 pass, `metal` 052eaa85b |

Logs: `results/repeats-stage2-min.txt` (M2), `results/studio/repeats-studio.txt`, `results/flexible-stage2-min.txt`, `results/repeats-fix-m2.txt` (62e1e2e95, 15 interleaved runs per tree). Nothing in the cut touches the random number kernels. A harness that runs the old and the new signature rewriter over all 73 kernel files (`probes/rewriter-compare.cpp`) finds identical output apart from 3 raw `EXTRA_ARGS` and `PARAMETER_ARGUMENTS` placeholders, which the host code replaces before the rewriter sees them.

The first two M3 Ultra runs of the cut failed to compile most kernels (`results/studio/ctest-min1.txt`, `ctest-min2.txt`): the regex rewriter lost newlines around preprocessor lines inside a parameter list (see what didn't work). Run min3 failed TestMetalCustomNonbondedForce, which wants the 31-argument message, so that came back. Runs min4 and min5 had no device throw, min5 after restoring MSL 3.2. Run min6 is 1e90e5b0a. There `probes/edge.py` gets "The METAL platform does not support multiple devices" for `DeviceIndex` "0,0", and Mixed and Double precision fail to compile with "'double' is not supported in Metal" (`results/studio/edge-after.txt`).

A few tests ran under `MTL_DEBUG_LAYER=1` (HarmonicBondForce, Sort, NonbondedForce, GBSAOBCForce, CustomCPPForce). All passed with API validation on, including launches that set 0 bytes of threadgroup memory (`results/studio/debug-*.txt`).

## Forces against Reference

`forces.py` builds the benchmark.py systems, evaluates forces and energy once on Metal single and once on Reference, and prints relative force error, largest component error and relative energy error. Logs: `results/forces-stage2.txt` (untuned, and `metal`), `results/forces-stage2-final.txt` (aa7464387), `results/forces-stage2-min.txt` (the minimum, M2), `results/forces-fix.txt` (62e1e2e95, M2, force errors identical to the minimum's to 4 digits), `results/studio/forces-studio-*.txt` (M3 Ultra).

| Test | Atoms | rel\|dF\|, every build | rel\|dE\| minimum, M2 | `metal`, M2 | minimum, M3 Ultra | `metal`, M3 Ultra |
|---|---:|---:|---:|---:|---:|---:|
| gbsa | 2,489 | 2.47e-05 | 6.0e-07 | 5.4e-07 | 6.5e-07 | 6.3e-07 |
| rf | 23,558 | 2.21e-05 | 2.3e-07 | 2.3e-07 | 2.1e-07 | 2.2e-07 |
| pme | 23,558 | 2.05e-05 | 1.3e-06 | 1.3e-06 | 1.2e-06 | 1.3e-06 |
| apoa1rf | 92,224 | 5.99e-05 | 8.9e-08 | 9.5e-08 | 5.4e-08 | 4.6e-08 |
| apoa1pme | 92,224 | 7.75e-05 | 7.4e-07 | 7.8e-07 | 5.8e-07 | 5.9e-07 |
| apoa1ljpme | 92,224 | 7.75e-05 | 1.0e-06 | 1.1e-06 | 6.1e-07 | 5.9e-07 |

Force errors agree across the two builds and the two chips to three digits, and to four on each chip. Energy errors are within a factor of 1.2 of `metal`'s everywhere. `metal` switches to the same fast functions as this branch only when a runtime accuracy check passes. This branch dropped that check and uses them unconditionally, so the M3 Ultra run below is the only test of fast math beyond the M2. The apoa1 systems have more than 90,000 atoms, so they also cover the large block path of the neighbor list.

## Benchmarks

`bench.sh` runs `examples/benchmarks/benchmark.py --platform Metal --precision single` on this branch and on `metal` 361452c5c, alternating which goes first in each round. benchmark.py times with the host clock: `datetime.now()` around `step()`, with a `getState()` to sync. Numbers are ns/day on the M2 mini, median of 3 interleaved rounds of 30 seconds. The minimum was timed before the device throw came back. That throw runs once at context creation, outside the timed steps.

### M2

The minimum (`results/bench-stage2-min`):

| Test | `metal` | minimum | Ratio | `metal` rounds | minimum rounds |
|---|---:|---:|---:|---|---|
| gbsa | 386.9 | 418.2 | 1.081 | 387.2 386.9 386.9 | 420.1 416.8 418.2 |
| rf | 253.7 | 254.9 | 1.005 | 253.7 253.2 254.6 | 254.4 254.9 255.3 |
| pme | 199.9 | 208.9 | 1.045 | 199.9 199.7 201.2 | 208.6 208.9 210.3 |
| apoa1rf | 58.9 | 69.3 | 1.176 | 58.9 58.9 59.1 | 69.2 69.5 69.3 |
| apoa1pme | 47.0 | 54.7 | 1.164 | 47.0 47.0 47.1 | 54.8 54.6 54.7 |
| apoa1ljpme | 33.9 | 40.6 | 1.197 | 33.9 33.9 34.0 | 40.6 40.7 40.5 |

Every ratio is within 0.6 percent of aa7464387's below, so the cut costs nothing on the M2.

aa7464387 (`results/bench-stage2-final`):

| Test | `metal` | aa7464387 | Ratio | `metal` rounds | aa7464387 rounds |
|---|---:|---:|---:|---|---|
| gbsa | 387.3 | 418.4 | 1.081 | 387.9 384.5 387.3 | 419.3 418.4 413.8 |
| rf | 253.9 | 253.7 | 0.999 | 255.3 253.9 253.9 | 254.2 253.7 253.2 |
| pme | 199.8 | 208.1 | 1.042 | 200.4 199.7 199.8 | 208.4 208.1 207.9 |
| apoa1rf | 59.0 | 69.3 | 1.174 | 59.0 59.0 59.0 | 69.2 69.3 69.4 |
| apoa1pme | 46.9 | 54.5 | 1.162 | 47.1 46.9 46.9 | 54.5 54.4 54.5 |
| apoa1ljpme | 33.9 | 40.5 | 1.193 | 33.9 33.9 33.9 | 40.5 40.5 40.4 |

Rounds vary by 1 percent or less. rf ties. Everything else is 4 to 19 percent faster than `metal`.

### M3 Ultra (owner at the keyboard, light CPU)

`studio/bench.sh` runs the same benchmark.py command on the Studio, interleaving the trees inside each test and reversing their order every other round. It writes the 1, 5 and 15 minute load averages before and after every run to `loads.txt`. The 1 minute load ranged from 1.2 to 7.5 in the two runs below. Three trees: `metal` 361452c5c, aa7464387 (stage 2 before the cut) and the minimum. First run (`results/studio-bench-3trees`), 3 rounds of 30 seconds:

| Test | `metal` | aa7464387 | Ratio | minimum | Ratio | `metal` rounds | aa7464387 rounds | minimum rounds |
|---|---:|---:|---:|---:|---:|---|---|---|
| gbsa | 1183.2 | 1020.4 | 0.862 | 994.3 | 0.840 | 1184.4 1180.4 1183.2 | 1021.0 1020.4 1012.8 | 989.8 1000.8 994.3 |
| rf | 692.7 | 606.8 | 0.876 | 614.3 | 0.887 | 679.4 692.7 693.8 | 602.0 611.3 606.8 | 605.8 621.5 614.3 |
| pme | 538.2 | 544.8 | 1.012 | 535.5 | 0.995 | 537.0 538.2 538.7 | 544.8 547.7 542.9 | 535.5 537.4 524.0 |
| apoa1rf | 286.3 | 300.5 | 1.050 | 299.8 | 1.047 | 286.3 286.7 286.3 | 299.9 300.5 300.8 | 299.5 300.9 299.8 |
| apoa1pme | 183.3 | 191.9 | 1.047 | 199.4 | 1.088 | 183.3 183.5 183.2 | 191.9 199.0 129.1 | 199.6 199.4 153.2 |
| apoa1ljpme | 128.4 | 52.2 | 0.407 | 156.2 | 1.217 | 128.2 128.4 128.6 | 44.4 72.6 52.2 | 156.7 82.4 156.2 |

The minimum against aa7464387 differed by less than 3 percent on gbsa, rf, pme and apoa1rf, and so did pme against `metal`. The rerun of those four (`results/studio-bench-rerun`, same method, 1 minute load 1.6 to 3.8):

| Test | `metal` | aa7464387 | Ratio | minimum | Ratio |
|---|---:|---:|---:|---:|---:|
| gbsa | 1172.7 | 995.5 | 0.849 | 1007.0 | 0.859 |
| rf | 692.5 | 609.4 | 0.880 | 610.2 | 0.881 |
| pme | 539.3 | 548.1 | 1.016 | 550.9 | 1.021 |
| apoa1rf | 286.4 | 300.7 | 1.050 | 300.0 | 1.048 |

Between the two runs the minimum's gap to aa7464387 changed sign on gbsa (-2.6 and +1.2 percent) and pme (-1.7 and +0.5 percent). So the cut is neutral on the M3 Ultra too, within run to run noise. pme ties `metal`, and apoa1rf is 5 percent faster. An earlier two-tree run (`results/studio-bench-stage2-min`, 1 minute load up to 13.9) gave the minimum gbsa 0.862, rf 0.889, pme 0.961, apoa1rf 1.048, apoa1pme 1.086 and apoa1ljpme 0.371.

Stage 2 itself does not hold on the M3 Ultra, before or after the cut:

- gbsa is 14 to 16 percent slower than `metal`, rf 11 to 12 percent. On the M2 they are 8 percent faster and even. The tuning table was measured on the M2 only, with its 10 cores. The M3 Ultra has 60 (`gpu-core-count`), so the block counts per core give 720 thread blocks and 2,400 force blocks for 2,489 atoms in gbsa.
- apoa1ljpme runs at a different speed in each process: 44 to 53, 72 to 99, or about 156 ns/day, against `metal`'s steady 128. The speed holds for the life of the process: 12 chunks of 200 steps vary by 15 percent or less within a process, and by a factor of 3.5 between processes (`probes/chunks.py`, `results/studio/apoa1ljpme-modes.txt`). aa7464387 shows the same spread, so the cut didn't cause it. apoa1pme has the same kind of outlier less often (107, 129, 153 against about 199). The M2 shows none of this: its apoa1ljpme rounds agree within 0.5 percent. I haven't found the cause. Something fixed at context creation decides it, since the chunks within a process agree.

The HIP kernels were not this fast as ported. Untuned (`results/bench-stage2-untuned`, same method), the ratios were gbsa 0.55, rf 0.86, pme 0.72, apoa1rf 1.06, apoa1pme 0.83, apoa1ljpme 0.78. Closing that took five one-line changes, each screened with one round of 15 seconds (`screen.sh`, `results/screen-*`):

| Change | gbsa | pme | rf | apoa1pme |
|---|---:|---:|---:|---:|
| Untuned, 3 rounds | 0.55 | 0.72 | 0.86 | 0.83 |
| HIP's `__expf`, `__logf`, `__frsqrt_rn` as `fast::` | 0.75 | 0.91 | 0.92 | 1.04 |
| 12 thread blocks per core, not 6 | 0.85 | 0.95 | 0.92 | 1.10 |
| RECIP as `fast::divide` | 1.07 | 0.98 | 0.92 | 1.14 |
| One tile per batch in findInteractingBlocks | 1.07 | 1.01 | 0.96 | |
| 40 nonbonded thread blocks per core, not 20 | 1.08 | 1.04 | 1.00 | |

The library compiles in safe math mode, so plain `exp`, `log`, `rsqrt` and `/` are the precise versions. HIP already asks for the fast intrinsics, so the first change only maps HIP's names. The last two rows were screened on gbsa, pme and rf only, with temporary environment variables. The final benchmark covers the apoa1 systems with all five changes. The knobs that lost: no single pairs (`MAX_BITS_FOR_PAIRS` 0, rf 0.89), `metal`'s 256-thread force blocks (rf 0.92), 128-thread force blocks (rf 1.02 but gbsa 1.05), 60 and 80 force blocks per core (within 1 percent of 40). Logs: `results/screen-knobs`, with the settings in `configs.txt` and `configs2.txt`.

A hybrid run located the gap before tuning: this branch's host layer with `metal`'s nonbonded code and the first two changes (`results/screen-h1-stage1-nonbonded`) gave rf 1.00 but gbsa 0.83 and pme 0.96. So rf's gap was in HIP's nonbonded code, and most of gbsa's was the precise divide.

Committing the nonbonded kernel before waiting on the interaction count is 3 lines that HIP doesn't have. Without them (`results/bench-variant-nocommit`, 3 rounds, all tuning in place) gbsa was 0.84, pme 0.90, rf 0.84, apoa1rf 1.11 and apoa1pme 1.11 against `metal`. That is 4 to 23 percent slower than HEAD, so the lines stay.

## What didn't work

- `MTL::CopyAllDevices()` returned NULL, so every test failed with "Error creating METAL stream". metal-cpp compiles the function out below a 10.11 deployment target, and OpenMM's CMake defaults to 10.7. The context now uses `MTL::CreateSystemDefaultDevice()`, as `metal` does.
- The mechanical rename named the platform "METAL". It has to be "Metal" for scripts and the checkpoint test.
- HIP's default of a separate PME stream. Each event between the queues commits a buffer, 4.01 commits per PME step against TestMetalCommandBatching's limit of 2.1, and it costs 13 percent on pme and 4 percent on apoa1pme (see MetalPlatform.cpp above). `DisablePmeStream` now defaults to true.
- `&blockSizeRange->x` fails in MSL (probe3.metal, "address of vector element requested").
- `thread unsigned int&` in a kernel file fails because the rewriter renames `thread`. `PRIVATE` works.
- `simd_shuffle` and `simd_shuffle_rotate_down` reject 64 bit types, which the GB kernels shuffle. Overloads split them into two 32 bit halves.
- MSL rejects `long long`, `max(0, uint)` and a redefined `FLT_MAX` (probe2.metal). `__threadfence()` needs MSL 3.2's `thread_scope_device`.
- HIP's kernels as ported ran at 0.55 to 0.86 of `metal` on the small systems. Safe math mode makes HIP's plain `1.0f/x` a precise divide, and HIP's thread block counts are sized for AMD compute units. See the tuning table.
- `MAX_BITS_FOR_PAIRS` 0 (no single pairs) and `metal`'s 256-thread force blocks were slower than HIP's defaults.
- Leaving the MSL language version to the OS default. The C++ tests pass that way, but the Python module compiled every kernel as an older MSL: program-scope `[[thread_position_in_threadgroup]]` variables, `atomic_float` and `nextafter` were all errors. The default seems to follow the SDK the host executable was built with, and Python's is older. benchmark.py skips a test whose context throws, so the first Studio benchmark wrote empty results for this branch without an error. `setLanguageVersion(3_2)` is back, and `studio/bench.sh` now logs a run that produced no result.
- The first regex rewriter joined a parameter to the preprocessor line after it (`constant mixed& _in_tol#ifdef ...`). After a first fix it joined a preprocessor line to the parameter after it (`#ifdef USE_LARGE_BLOCKSdevice ...`). The first came from `regex_match` dropping the whitespace around a parameter, the second from copying a directive without its newline. 54 of 54 tests failed on the M3 Ultra, then 28 of 54. It also read `real4 periodicBoxVecZ EXTRA_ARGS` as a type and a name. Directive lines now keep their newline, and trailing capitalized macro names stay after the parameter.

## Review findings not fixed

A read-only review of the stage 2 diff found these. None changes forces in the tests.

- CCMA: the host resets the converged flag by writing shared memory, while the tail iterations of the previous solve can still be in the open command buffer. The verifier's reading narrows it: it needs more than 1,024 constraints (below that CCMA runs as one kernel) and a solve that hits the 150-iteration cap while converging at iteration 147 or 148. The result is one step with loose constraints. HIP has the same race with an async stream. Command batching makes it more likely. `metal` avoids it by reading `ccmaConverged` instead. Not changed, to stay with HIP.
- sort.metal: the last-block reduction in `computeRange` reads other threadgroups' results with plain loads. `__threadfence()` orders them, but MSL only guarantees cross-threadgroup visibility for `coherent(device)` buffers. A stale value makes uneven buckets, which costs speed, not order, as long as every key still lands in a bucket. A key below a stale minimum makes a negative quotient, which `assignElementsToBuckets` converts to `unsigned int`. If Apple GPUs don't saturate that conversion to 0, the key goes to the last bucket and the order breaks. Experiment 021 found float to long conversions wrap on the M3.
- `__launch_bounds__` expands to nothing, and `executeKernelFlat` doesn't check the block size against the pipeline's limit. `computeBucketPositions` can ask for 1024 threads.

## Risks of the cut

- A machine with no `AGXAccelerator` service in the IORegistry, such as a VM, gets a NULL core count, and `CFNumberGetValue` dereferences it. `metal` fell back to 8 cores.
- Apple GPUs run 32-wide SIMD groups. On a GPU that didn't, the kernels would compute wrong results instead of throwing.
- A NULL shared event or command queue crashes at its next use instead of throwing.
- `MetalEvent::wait` no longer checks its command buffer for an error. The queue reports a failed buffer at its next commit or finish.
- `std::regex` costs little: the M2 ctest took 236 s against 234 s for aa7464387 (`results/ctest-stage2-min.txt`, `results/ctest-stage2-final.txt`).

## Files

- `delta.sh`: the metric.
- `leased.sh`: holds the mini lease around one command.
- `studio/`: the M3 Ultra versions of build, ctest, bench and the lease wrapper. They work under `/tmp/openmm-metal-bench/hipdelta`, with a venv per tree.
- `forces.py`: Metal against Reference.
- `bench.sh`, `summarize.py`: interleaved benchmark rounds and their medians.
- `screen.sh`: one benchmark round per setting of temporary environment knobs.
- `install.sh`, `final.sh`: rebuild and install on the mini, then ctest, forces, the FlexibleBarostat repeats and the benchmark.
- `probes/`: MSL compile probes and `mslc.swift`, the compiler driver (`swiftc -O mslc.swift`). `rewriter-compare.cpp` runs the old and new signature rewriters over kernel files. `chunks.py` times an apoa1 system in 200-step chunks. `rfdebug.py` shows the exception benchmark.py hides. `edge.py` tries Mixed and Double precision and `DeviceIndex` "0,0".
- `results/`: raw logs.

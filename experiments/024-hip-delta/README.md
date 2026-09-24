# 024: Metal as the smallest diff from HIP

peastman plans to write the Metal platform himself, starting from CUDA or HIP, and to read ours as a reference. So the product here is a readable "HIP to Metal in N lines" diff. Every line that differs from HIP should exist because Metal needs it or because it measurably speeds things up.

The OpenMM branch is `metal-hipdelta` on the `mini` remote, from merge base 3c9effc96. The comparison build is `metal` at 361452c5c. Stage 2 is commits 495350e28 (HIP's nonbonded kernels), 24c34d794 (tuning), aa7464387 (a destructor fix from review) and 1e90e5b0a (the cut to the minimum: no added comments, no defensive code HIP lacks). 62e1e2e95 applies the verifier's review. Stage 3 looked for measured speedups and found none that passes the tests, so it has no commit. Stage 4 is 089374b36 and b753d9a6a: mixed precision with df64, gated against `metal` at 052eaa85b. Round 2 followed the lead's review: f341bf739 restores the 31-argument message a test expects, 5d9e2388e throws when the IORegistry has no GPU core count, and 9074c38f1 finds the sort range in one threadgroup, which fixes apoa1ljpme's per-process spread on the M3 Ultra. The M3 Ultra tuning pass found no setting that holds 0.97x `metal` on both chips (see round 2).

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
| Stage 4: mixed precision with df64, b753d9a6a | 474 | 589 (df64) | 1,063 |
| 31-argument message restored, f341bf739 | 476 | 589 | 1,065 |
| Throw without a GPU core count, 5d9e2388e | 478 | 589 | 1,067 |
| Sort range in one threadgroup, 9074c38f1 | 479 | 589 | 1,068 |

The table's count leaves out code a reader has to write too:

- All of `platforms/metal`, CMake files and tests included, adds 995 lines at 62e1e2e95 (1,262 at aa7464387) and 1,892 at b753d9a6a (1,897 at 9074c38f1), where df64.metal and TestMetalMixedPrecision.cpp are 885 of the 897 new lines. The tests are most of the difference: 249 lines added to HIP's test files and 257 in Metal-only tests (TestMetalCommandBatching, TestMetalFFT).
- Outside `platforms/metal` the branch through 62e1e2e95 changes 13 files, +100 and -45 lines, most of it shared with `metal`: the top-level CMakeLists.txt (12), the common kernels dpd, gayBerne and minimize and ExpressionUtilities.cpp (24), a `PRIVATE` macro in the CUDA, HIP and OpenCL common kernels (3), the vkFFT.h Metal backend patch (+10 -28, with a 12-line note), TestCheckpoints.h and TestCustomIntegrator.h (33), and the developer guide (6).
- The `PRIVATE` line in `platforms/hip/src/kernels/common.hip` means delta.sh diffs against a HIP that is 1 line modified.
- metal-cpp is vendored: 35,021 lines in 127 files.

Stage 4 adds 38 lines and removes 24 in 6 more common files (see stage 4). Without df64 the baseline is 2,038, the number to hold stages 1 to 3 against, since they are single precision only. With mixed precision back, b753d9a6a's 1,063 compares with `metal`'s 2,721, and 9074c38f1's 1,068 does too. Logs: `results/delta-*.txt`.

## Delta per file at HEAD, 9074c38f1

The source carries no comments beyond what HIP's files already have, including their license headers. Every reason lives here instead.

| File | Added | Why |
|---|---:|---|
| src/MetalContext.cpp | 132 | Kernel signature rewriter, 42 lines. MSL wants `device` on pointer parameters and takes scalar and vector arguments only by `constant` reference, so a value parameter becomes `constant T& _in_x` plus a copy `T x = _in_x;` at the top of the body. Preprocessor lines inside a parameter list are copied into that prologue too. Two `regex_replace` calls rename `thread`, which MSL reserves and the common kernels use as a variable name, and turn `long long` into `long`, which MSL lacks. Compile, 15 lines: `metal_stdlib` header, MSL 3.2, safe math with precise functions. getKernel, 19 lines: pipeline reflection records the byte size of each `_in_` argument. Launch, 13 lines: `setBytes` for those, `setBuffer` for the rest, into the queue's open encoder. Device, queue and properties, 18 lines, including the GPU core count from the IORegistry, which Metal doesn't report, and a throw when there is none (5d9e2388e). The 31-argument message, 2 lines (f341bf739): TestMetalCustomNonbondedForce expects it. Host memory and releases, 8 lines. Tuning, 2 lines: 12 thread blocks per core and RECIP as `fast::divide`. Mixed precision, 9 lines: df64.metal in `createModule` and `doubleToString` (stage 4). |
| src/kernels/common.metal | 105 | CUDA names for MSL built-ins (program-scope `threadIdx` and friends, `__syncthreads`, `__threadfence`, `__shared__`), atomics (the M1 and M2 have no 64 bit atomic add, and MSL has no float atomic min or max), the `make_` names the kernels use, `f` suffix math names, erf and erfc (MSL has neither), `__float2half_ru`, realToFixedPoint without `long long`. HIP's `__expf` and `__logf` are its fast intrinsics and map to `fast::exp` and `fast::log`. `__fsqrt_rn` maps to `precise::sqrt`. HIP's `__frsqrt_rn` rounds to nearest, so mapping it to `fast::rsqrt` is not a match: it is a speed choice from the tuning table below. `MEM_FENCE` is empty: HIP's hot bonded kernels call it, and a device fence there costs time for ordering that the kernels don't need within a SIMD group. `SYNC_WARPS` is `simdgroup_barrier`. |
| src/MetalQueue.cpp | 60 | One open command buffer and compute encoder per queue. Commits happen at upload, download, event and step boundaries. Committed buffers wait in a deque and are released once complete, and a failed buffer throws at the next commit or finish. The lock is recursive because CustomCPPForce uploads from a worker thread. Autorelease pools wrap the metal-cpp calls that return autoreleased objects, since Python threads have no pool. |
| include/MetalQueue.h | 21 | Declarations for the above, and the `metalStream_t` typedef. `getCommitCount` and its counter, 5 lines, exist for TestMetalCommandBatching. Metal reports no count of committed command buffers, and no other API shows whether a step went out as one buffer or many. Batching is what the no-commit variant below lost 4 to 23 percent to, so the test guards it and the lines stay. |
| src/MetalPlatform.cpp | 21 | macOS 15 and GPU family Apple7 check, device name through an autorelease pool (metal-cpp returns an autoreleased string), one device, PME stream off by default. That default is measured: on HEAD with it true, pme ran 208.0 and 208.5 ns/day against 183.7 and 183.4 with it false, and apoa1pme 54.2 and 54.3 against 51.9 and 52.1 (verifier, M2, host clock, 2 rounds of 20 s). Each event between the two queues commits a command buffer, which is where the time goes. A second context throws: with `DeviceIndex` "0,0" two contexts on the one GPU returned 0 kJ/mol for a bond whose energy is 0.5. |
| src/MetalArray.cpp | 17 | Shared storage buffers of at least 16 bytes (Metal can't create empty buffers). Upload and download finish the queue and then memcpy. copyTo is a blit in the open command buffer. |
| src/MetalEvent.cpp | 17 | MTLSharedEvent signal and wait. A failed buffer is reported by the queue's next commit, not by the event. |
| src/MetalFFT3D.cpp | 17 | VkFFT's Metal backend. vkFFT.h compiles the metal-cpp implementation into the file that includes it, so only this file includes it, and the header forward-declares a wrapper struct. VkFFT compiles with fast math, so `useLUT` takes twiddle factors from a table. VkFFT's Metal backend only encodes into a given encoder, so the FFT goes into the open one. |
| include/MetalContext.h | 15 | Host vector typedefs (`int2`, `float4`, `uint1`) that HIP gets from its runtime headers, `getCurrentStream` returning the queue, the reflection map, a 64-bit atomics getter that returns false, `getSupportsDoublePrecision` returning `useMixedPrecision` and the `doubleToString` override (stage 4). |
| src/kernels/findInteractingBlocks.metal | 14 | See kernel rewrites below. |
| src/kernels/intrinsics.metal | 12 | `warpSize`, `__shfl`, `__shfl_down`, `__ballot` on simd_ functions. The GB kernels shuffle 64 bit values, which `simd_shuffle` rejects, so two overloads split them into 32 bit halves. |
| src/MetalNonbondedUtilities.cpp | 10 | Shared buffer for the interaction count, ComputeEvent, a commit before waiting on the count. Tuning: 40 force thread blocks per core, one tile per batch. |
| src/kernels/sort.metal | 10 | `extern __shared__` becomes a `[[threadgroup(0)]]` parameter, `__threadfence()` before the last-block reduction, `max(0u, ...)` for MSL's stricter overloads. |
| src/MetalSort.cpp | 2 | `maxThreadgroupMemoryLength` for HIP's device attribute query, and `rangeKernelBlocks = 1` (9074c38f1). HIP's computeRange reduces the per-block ranges in whichever block finishes last. On the M3 Ultra that left the PME atom sort in a slow mode in about one process in three, even with the fence. One threadgroup has no cross-threadgroup reduction. `metal` sizes this kernel the same way. See round 2. |
| include/MetalArray.h | 6 | `metal-cpp` include and the handle typedefs `metalDevice_t`, `metalDeviceptr_t`, `metalModule_t`, `metalFunction_t`. With them HIP's declarations stay as they are. |
| src/MetalIntegrationUtilities.cpp | 6 | CCMA's converged flag in a shared buffer, and a ComputeEvent. |
| other 6 files | 14 | Members and includes for the above, the platform name "Metal". |
| src/kernels/nonbonded.metal | 0 | HIP's kernel compiles unchanged. |
| src/kernels/df64.metal | 589, Metal only | Mixed precision, see stage 4. |

### Removed in the cut, and why

The lead asked for no defensive code HIP doesn't have. The cut took aa7464387 from 731 added lines to 467:

- Every comment we had added, 101 lines. HIP's own comments stay, including `// METAL-TODO: This may require tuning` above `numTilesInBatch`.
- The SIMD width check in getKernel, the throw for double and mixed precision and the 8-core fallback when the IORegistry has no core count. HIP has none of these. 5d9e2388e later made a missing core count throw (round 2). Double and mixed precision now fail at kernel compile with "'double' is not supported in Metal".
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

- The 31-argument message, 2 lines. A kernel with too many arguments still fails to compile with an OpenMMException, and TestMetalCustomNonbondedForce now looks for the compiler's own text, "no 'buffer' resource location available". f341bf739 reverts this: the lead's rule is that tests are the contract, and this cut edited a test's expectation to save 2 lines. The test and the message are back as they were.
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

sort.metal: dynamic threadgroup memory has to be a kernel parameter, and the last-block reduction needs a device-scope fence to see other threadgroups' writes. The fence wasn't enough on the M3 Ultra, so 9074c38f1 launches the range kernel as one threadgroup and the reduction never crosses threadgroups.

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
| Stage 3 fast math mode b46bf2193 (dropped), Single | M2 | 53/54, TestMetalConstantPotentialForceSingle fails 3/3: conjugate gradient not converged |
| Stage 3 fast math mode b46bf2193 (dropped), Single | M3 Ultra | 51/54, the same ConstantPotential failure plus the flexible and anisotropic barostats |
| `metal` 052eaa85b, Mixed | M2 | 56/56 pass (`-R "TestMetal.*Mixed"`, so TestMetalMixedPrecisionSingle too) |
| Stage 4 b753d9a6a, Single and Mixed | M2 | 109/110, TestMetalMonteCarloFlexibleBarostatSingle failed once (stochastic, see below) |
| Stage 4 b753d9a6a, Single and Mixed | M3 Ultra | 110/110 pass. An earlier run of the same tree failed TestMetalMonteCarloFlexibleBarostatSingle once, then passed 5/5 repeats |
| Round 2 5d9e2388e, Single and Mixed | M2 | 108/110, TestMetalMonteCarloAnisotropicBarostat Single and Mixed failed once each. Repeats of the anisotropic barostat in single precision: 5/5 pass, `metal` 052eaa85b 4/5 (`results/repeats-restore-m2.txt`) |
| Round 2 5d9e2388e, Single and Mixed | M3 Ultra | 110/110 pass (`results/studio/ctest-5d9e.txt`) |
| Round 2 9074c38f1, Single and Mixed | M2 | 110/110 pass (`results/ctest-rangefix.txt`). FlexibleBarostat repeats 5/5 on both trees (`results/flexible-rangefix.txt`). Force errors identical to 62e1e2e95's, energy errors within their run to run spread (`results/forces-rangefix.txt`) |
| Round 2 9074c38f1, Single and Mixed | M3 Ultra | 110/110 pass (`results/studio/ctest-9074.txt`) |

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
| TestMetalMonteCarloFlexibleBarostatSingle (M2, b753d9a6a; M3 Ultra, the first stage 4 run) | expected 3, found 3.648 (TestMonteCarloFlexibleBarostat.h:233, M3 Ultra) | 4/5 pass (M2), 5/5 pass (M3 Ultra) | 4/5 pass, `metal` 052eaa85b (M2) |

Logs: `results/repeats-stage2-min.txt` (M2), `results/studio/repeats-studio.txt`, `results/flexible-stage2-min.txt`, `results/repeats-fix-m2.txt` (62e1e2e95, 15 interleaved runs per tree), `results/repeats-stage4-flexible-m2.txt`, `results/studio/repeats-stage4-flexible.txt`. Nothing in the cut touches the random number kernels. A harness that runs the old and the new signature rewriter over all 73 kernel files (`probes/rewriter-compare.cpp`) finds identical output apart from 3 raw `EXTRA_ARGS` and `PARAMETER_ARGUMENTS` placeholders, which the host code replaces before the rewriter sees them.

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

Force errors agree across the two builds and the two chips to three digits, and to four on each chip. Energy errors are within a factor of 1.2 of `metal`'s everywhere. `metal` switches to the same fast functions as this branch only when a runtime accuracy check passes. This branch dropped that check and uses them unconditionally. The check picks the fast versions on both chips here (see fast math accuracy under stage 3). The apoa1 systems have more than 90,000 atoms, so they also cover the large block path of the neighbor list.

Stage 4, b753d9a6a: single precision gives the same force errors as 62e1e2e95 to 4 digits on the M2 (`results/forces-stage4.txt`). Mixed precision gives the same force errors as single to 4 digits on both chips, and energy errors between 4.9e-08 and 1.3e-06 (`results/forces-stage4-mixed.txt`, `results/studio/forces-stage4-single.txt`, `results/studio/forces-studio-stage4-mixed-final.txt`). Mixed precision keeps forces in float, so it can't do better against Reference here. What it buys is double-float accumulation in the integrators, which `TestMetalMixedPrecision` tests directly and the Mixed variants of the integrator tests exercise.

## Benchmarks

Every M3 Ultra timing here was taken on the night of 2026-09-23 to 24 UTC with the owner away. Each section gives the load the runs saw.

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

b753d9a6a, stage 4, against the current `metal` 052eaa85b (`ab.sh`, same method, `results/bench-stage4`). Single precision runs the same code as 62e1e2e95, and the ratios match 62e1e2e95's own run (`results/bench-fix-postcommit`, the variant without the post-force commit) within 0.4 percent:

| Test | `metal` 052eaa85b | b753d9a6a | Ratio | `metal` rounds | b753d9a6a rounds |
|---|---:|---:|---:|---|---|
| gbsa | 389.0 | 415.6 | 1.069 | 390.2 386.4 389.0 | 417.8 415.6 413.4 |
| rf | 253.5 | 253.3 | 0.999 | 253.6 253.5 253.5 | 254.6 252.7 253.3 |
| pme | 199.2 | 207.9 | 1.044 | 199.3 198.9 199.2 | 208.2 207.9 207.6 |
| apoa1rf | 59.0 | 69.3 | 1.175 | 59.0 58.9 59.0 | 69.3 69.3 69.4 |
| apoa1pme | 47.0 | 54.5 | 1.161 | 47.0 47.0 46.9 | 54.7 54.4 54.5 |
| apoa1ljpme | 33.9 | 40.5 | 1.193 | 33.9 33.9 33.9 | 40.5 40.5 40.4 |

Mixed precision, same method (`PRECISION=mixed ab.sh`, `results/bench-stage4-mixed`). Both builds run df64 in the integrators, so this compares the rest of the code under mixed precision:

| Test | `metal` 052eaa85b | b753d9a6a | Ratio | `metal` rounds | b753d9a6a rounds |
|---|---:|---:|---:|---|---|
| gbsa | 305.2 | 321.2 | 1.052 | 305.2 304.8 305.2 | 322.7 321.2 321.0 |
| rf | 175.6 | 178.9 | 1.019 | 175.6 175.7 175.6 | 180.2 178.9 178.7 |
| pme | 150.2 | 155.4 | 1.034 | 149.6 150.3 150.2 | 155.4 155.4 154.8 |
| apoa1rf | 47.1 | 53.8 | 1.142 | 47.1 47.2 47.1 | 53.6 53.8 53.8 |
| apoa1pme | 39.1 | 44.2 | 1.130 | 39.1 39.1 39.1 | 44.3 44.2 44.2 |
| apoa1ljpme | 29.7 | 34.6 | 1.165 | 29.7 29.7 29.7 | 34.6 34.6 34.6 |

Mixed precision costs this branch 15 to 29 percent against its own single precision, and `metal` 12 to 31 percent.

9074c38f1, the one-threadgroup sort range, against `metal` 052eaa85b (`bench.sh`, 3 interleaved rounds of 30 seconds, host clock, `results/bench-rangefix`):

| Test | `metal` 052eaa85b | 9074c38f1 | Ratio | `metal` rounds | 9074c38f1 rounds |
|---|---:|---:|---:|---|---|
| gbsa | 385.6 | 413.2 | 1.072 | 384.9 386.7 385.6 | 413.2 413.1 413.6 |
| rf | 253.4 | 253.7 | 1.001 | 253.4 253.2 253.5 | 253.3 253.7 254.1 |
| pme | 199.5 | 207.1 | 1.038 | 201.3 199.3 199.5 | 207.2 206.9 207.1 |
| apoa1rf | 59.0 | 69.3 | 1.175 | 59.0 59.0 59.0 | 69.4 69.3 69.2 |
| apoa1pme | 47.0 | 54.3 | 1.154 | 47.0 47.0 47.1 | 54.3 54.3 54.4 |
| apoa1ljpme | 33.9 | 40.0 | 1.181 | 34.0 33.9 33.9 | 40.0 40.0 40.1 |

The M2 never showed the spread. Against 5d9e2388e's 2 rounds of 15 seconds in `results/m2-tiles` (HEAD column), apoa1pme and apoa1ljpme dropped 0.7 and 1.2 percent, since one threadgroup scans all 92,224 keys. The other four tests moved 0.5 percent or less, which is inside run to run noise.

### M3 Ultra (owner away)

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
- apoa1ljpme runs at a different speed in each process: 44 to 53, 72 to 99, or about 156 ns/day, against `metal`'s steady 128. The speed holds for the life of the process: 12 chunks of 200 steps vary by 15 percent or less within a process, and by a factor of 3.5 between processes (`probes/chunks.py`, `results/studio/apoa1ljpme-modes.txt`). aa7464387 shows the same spread, so the cut didn't cause it. apoa1pme has the same kind of outlier less often (107, 129, 153 against about 199). The M2 shows none of this: its apoa1ljpme rounds agree within 0.5 percent. I haven't found the cause. Something fixed at context creation decides it, since the chunks within a process agree. Round 2 found it: HIP's multi-threadgroup range reduction in the PME atom sort, fixed in 9074c38f1. So the minimum's 156.2 and 1.217 for apoa1ljpme in the table above came from that race, not from a real speedup. The fixed branch runs apoa1ljpme at a steady 143.6 to 143.9, 1.12x `metal`.

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

## Stage 3: measured speedups

No stage 3 commit. The one candidate that sped up the M2 fails a test, and nothing else beat run to run noise on either chip.

### Fast math mode fails TestMetalConstantPotentialForce

HIP compiles its kernels with `-O3 -ffast-math`. This branch compiles in safe math mode and maps only HIP's fast intrinsics to `fast::`. Switching the library to `MTL::MathModeFast`, with functions still precise, is a one-line change. The M2 screen (`ab.sh`, 2 interleaved rounds of 15 seconds, host clock, `results/screen-stage3-fastmath`), ratios against HEAD:

| Variant | gbsa | rf | pme | apoa1pme |
|---|---:|---:|---:|---:|
| Fast math mode | 1.020 | 0.997 | 1.026 | 1.023 |
| Fast functions (`MTL::MathFloatingPointFunctionsFast`) | 1.008 | 1.004 | 1.008 | 1.002 |

HEAD's two rounds agree within 0.6 percent, so fast math mode's 2 to 2.6 percent is real on the M2. Committed as b46bf2193, it passed forces (`results/forces-stage3.txt`, force errors equal to HEAD's to 3 digits) but failed ctest: TestMetalConstantPotentialForceSingle throws "Constant potential conjugate gradient iterations not converged", 3 times out of 3 (`results/ctest-stage3.txt`, `results/repeats-stage3-constantpotential.txt`). Fast mode allows reassociation and assumes finite values. I didn't trace which kernel of the solve breaks. Fixing it would mean safe mode for some kernels and fast for others, which grows the diff, so the commit is dropped. It stays on the local branch `metal-hipdelta-fastmode` and was never pushed. Fast mode would also break stage 4, since df64 needs safe mode.

Fast functions gain under 1 percent on every test, inside the noise, so they aren't worth a line either.

### M3 Ultra block shapes don't close the gbsa and rf gap (owner away)

gbsa is 14 to 16 percent and rf 11 to 12 percent slower than `metal` on the M3 Ultra, while the M2 is faster or even. The tuning was done on the M2's 10 cores, so the Studio screen (`studio/screen.sh`, one run of 10 seconds per setting, 1 minute load 1.5 to 4.5, `results/studio/screen-stage3`) tried other block counts and shapes through temporary environment variables. Ratios against the mean of two HEAD runs, which themselves differ by 1.7 percent on gbsa, 1.0 on rf and 0.2 on pme:

| Setting | gbsa | rf | pme |
|---|---:|---:|---:|
| 6 blocks of 256 per core (`metal`'s shape) | 1.012 | 1.022 | 0.988 |
| 12 blocks of 128 | 1.017 | 1.020 | 0.955 |
| 20 blocks of 64 | 1.019 | 1.014 | 0.963 |
| 80 blocks of 64 | 1.019 | 1.009 | 0.926 |
| 40 blocks of 128 | 0.995 | 1.003 | 0.961 |
| Fast functions | 0.999 | 1.003 | 0.935 |
| Fast math mode | 1.003 | 1.008 | 1.002 |
| 6 thread blocks per core, not 12 | 0.996 | 0.994 | 0.978 |
| 24 thread blocks per core | 0.994 | 0.989 | 0.989 |

The best setting gains 2 percent, against a 14 percent gap, and costs pme. The load rose from 2 to 4.5 during the pme runs, so pme's losses are partly noise, but none of these is a win. The gap is in the kernels, not the launch shape. I didn't try `metal`'s nonbonded kernels: they need `metal`'s nonbonded host code, a few hundred lines, and on the M2 they were slower (the hybrid in stage 2 gave gbsa 0.83).

### Fast math accuracy on both GPUs

`probes/fastacc.swift` runs `metal`'s runtime check, the one this branch dropped: `fast::rsqrt`, `fast::divide`, `fast::exp` and `fast::log` on 20 values from 1e-4 up by factors of pi, taking a fast function only if its error is below 1e-6. It then sweeps 1e6 values from 1e-4 to 1e4 (`results/fastacc-m2.txt`, `results/studio/fastacc-m3ultra.txt`):

| Function | Check, M2 | Check, M3 Ultra | Sweep, M2 | Sweep, M3 Ultra |
|---|---:|---:|---:|---:|
| rsqrt | 5.9e-08 | 5.1e-08 | 8.5e-08 | 7.6e-08 |
| divide | 7.2e-08 | 5.1e-08 | 8.9e-08 | 7.6e-08 |
| exp | 3.2e-07 | 3.2e-07 | 3.7e-06 | 3.7e-06 |
| log | 6.1e-07 | 1.5e-07 | 5.7e-05 | 2.7e-07 |

`metal`'s check picks the fast version of all four on both chips, so dropping it changes nothing on these two. The sweep errors are relative. The M2's log error of 5.7e-05 is at arguments just outside the 1e-3 band the sweep skips around 1, where log itself is about 1e-3, so the absolute error there is about 6e-08. The M3 Ultra's fast log is more accurate near 1. Chips other than these two are untested.

## Stage 4: mixed precision with df64

Apple GPUs have no double precision, so stage 2 dropped Mixed and Double. Stage 4 brings Mixed back as its own layer, in two commits on 62e1e2e95: 089374b36 changes common code and b753d9a6a adds the Metal part. Double stays unsupported.

HIP's host code already handles mixed precision: it allocates double arrays, passes doubles to `setArg` and defines `mixed` as `double`. So the Metal layer only has to give the kernels a type called `double`. In mixed precision `createModule` puts `df64.metal` after `using namespace metal;`. That's `metal`'s double-float type with its comments removed, 589 lines. Its last 8 lines are `#define double df64` and the same for `double2` to `double4` and `make_double2` to `make_double4`. Device and constant memory hold df64 values as IEEE doubles: every load decodes and every store encodes. So the host code, the kernel arguments and the downloads see ordinary doubles, and no host code changes for them.

| Change | Lines | Why |
|---|---:|---|
| `df64.metal` | 589 | The double-float type, from `metal` |
| MetalContext.cpp, `createModule` | 2 | Include df64.metal in mixed precision |
| MetalContext.cpp/.h, `doubleToString` | 8 | A double constant a float can't hold becomes `df64(hi, lo)`. Without it, `(double) 0.1` in a kernel is only float accurate |
| MetalContext.h, `getSupportsDoublePrecision` | 1 changed | Returns `useMixedPrecision`, so kernels that test for double support take their mixed paths |
| ComputeContext.h, `doubleToString` virtual | 1 changed | So Metal can override it |
| integrationUtilities.cc, noseHooverIntegrator.cc | 8 changed | `cond ? mixedValue : 0` is ambiguous when `mixed` is a class, so the 0 becomes `(mixed) 0`. Plain doubles don't care |
| CommonMinimizeKernel.h/.cpp, minimize.cc | 29 added, 15 removed | Metal has no 64-bit atomics. Instead of throwing, the minimizer runs its reductions into doubles in a single thread block, from `metal`. The stale comment that Metal only supports single precision goes |
| TestMetalMixedPrecision.cpp | 296 | `metal`'s df64 tests: arithmetic, conversions, IEEE storage round trips, math functions, and the compile errors for deleted functions |
| tests/CMakeLists.txt | 3 | Register each Metal test in mixed precision too. QTBIntegrator calls `cos` on mixed values, which df64 deletes, so its mixed test expects that compile error, as on `metal` |

delta.sh at b753d9a6a (`results/delta-stage4.txt`): 474 added lines in shared files (10 more than 62e1e2e95), 589 in df64.metal, and 1,892 in all of `platforms/metal` (897 more). Outside `platforms/metal`, stage 4 adds 38 lines and removes 24 across 6 common files.

### df64 design, moved from the stripped comments

- A df64 is the unevaluated sum hi + lo of two floats with hi = RN(hi + lo), a double-word number (Definition 1.4 in Joldes, Muller, Popescu, "Tight and rigorous error bounds for basic building blocks of double-word arithmetic", ACM TOMS 44(2), 2017, JMP below). It has 48 significand bits and the float exponent range. Apple GPUs flush float subnormals, so full precision holds down to about 2^-102, and below that it degrades to float.
- Relative error bounds, u = 2^-24, without over- or underflow: df64 + df64 is JMP Algorithm 6, 3u^2 + 13u^3. df64 * df64 is Algorithm 12, 4u^2 (Muller and Rideau, ACM TOMS 48(1), 2022, Theorem 2.8). df64 / df64 is Algorithm 17, 15u^2 + 56u^3. df64 + float, * float and / float are Algorithms 4, 9 and 15, with 2u^2, 2u^2 and 3u^2.
- sqrt is one correction of `precise::sqrt` (bound 25/8 u^2). `metal::sqrt` under safe math is off by an ulp on about a quarter of inputs on the M3, which breaks the bound. exp and log are a Taylor series with argument reduction and a Newton-style correction on top of the float log.
- df64 needs safe math mode. Fast and relaxed modes allow reassociation, which folds the error terms of two-sum and two-product to zero. This branch compiles in safe mode already, and stage 3 kept it that way.
- sin, cos, tan, their inverses, the hyperbolic functions, erf, erfc and pow have no df64 versions. They're deleted, so a mixed argument is a compile error instead of a silent narrowing to float.
- `atomicAdd` on df64 is deleted too, since no Apple GPU has 64-bit float atomics and a df64 spans two words.
- `fast::` and `precise::` get df64 overloads of sqrt, rsqrt, exp, log and divide, because the host maps SQRT, RECIP and friends to qualified names, and a qualified call sees only that namespace.

## Round 2: the M3 Ultra

The lead's gate for a tuning change: at least 0.97x `metal` 052eaa85b on every benchmark on both the M3 Ultra and the M2, with a per-GPU branch allowed only at 3 lines or fewer. No setting passes. gbsa stays at 0.86 to 0.93 on the M3 Ultra under every knob tried.

The owner was away, but the Studio wasn't idle. The 1 minute load was 1.7 to 6.0 in screen 1 and 1.5 to 3.8 in screen 2, from a VM, a codegraph index, powermetrics and Chrome. Every run logs its load in `loads.txt`.

### Tuning screen

`studio/screen.sh`, one run of 15 seconds per setting, host clock, ratios against `metal` 052eaa85b in the same screen (`results/studio/screen-m3-1`, `screen-m3-2`). The knobs were temporary environment variables and never committed.

| Setting | gbsa | rf | pme |
|---|---:|---:|---:|
| HEAD, screen 1 | 0.864 | 0.881 | 1.013 |
| HEAD, screen 2 | 0.856 | 0.897 | 1.020 |
| 2 tiles per batch | 0.935 | 0.966 | 1.026 |
| 4 tiles per batch, screen 1 | 0.933 | 1.007 | 1.075 |
| 4 tiles per batch, screen 2 | 0.878 | 1.077 | 1.103 |
| 8 tiles per batch | 0.870 | 1.068 | 1.118 |
| 16 tiles per batch | 0.890 | 1.088 | 1.050 |
| 4 tiles, 24 thread blocks per core | 0.903 | 1.035 | 1.104 |
| 4 tiles, 6 force blocks of 256 per core (`metal`'s shape) | 0.885 | 1.040 | 1.080 |
| 4 tiles, 20 force blocks per core | 0.868 | 1.041 | 1.095 |
| 4 tiles, precise `exp` and `log` | 0.880 | 1.017 | 1.109 |
| 6 or 24 thread blocks per core, not 12 | 0.856, 0.887 | 0.875, 0.873 | 0.978, 0.986 |
| Force blocks: 6 of 256, 12 of 128, 20, 80, 80 of 32 per core | 0.855 to 0.876 | 0.854 to 0.890 | 0.982 to 1.006 |
| Precise `rsqrt`, divide, or `exp` and `log` | 0.851 to 0.887 | 0.851 to 0.861 | 0.964 to 1.016 |

Screen 1's `metal` gbsa was 1189.6 ns/day and screen 2's 1203.1, so a single 15 second run moves about 1 percent. HEAD's rf moved 1.6 percent between the screens and 4 tiles' gbsa 5.5 percent.

On the M2, 4 tiles per batch costs nothing (`results/m2-tiles`, `ab.sh`, 2 interleaved rounds of 15 seconds, host clock): against `metal` 052eaa85b it gave gbsa 1.080, rf 1.003, pme 1.040, apoa1rf 1.172, apoa1pme 1.162 and apoa1ljpme 1.191, where HEAD gave 1.081, 1.004, 1.041, 1.171, 1.161 and 1.190.

The best trade-off is HIP's own line, `numTilesInBatch = numAtomBlocks < 2000 ? 4 : 1`. It gives the small systems 4 tiles and keeps 1 for apoa1's 2,882 blocks, and it takes 1 line off the delta instead of adding one. It lifts rf from 0.88 to 1.01 or better and pme to 1.07 or better on the M3 Ultra, and gbsa from 0.86 to 0.88 or 0.93. gbsa still misses 0.97, so the gate fails and the line isn't committed. I recommend it anyway: it is HIP's code, it shrinks the diff, and it helps every M3 Ultra test without costing the M2 anything. The gbsa gap is there with or without it.

### Where gbsa loses

`probes/split.py` builds one benchmark system, drops force classes, and times chunks in fresh contexts (`results/studio/split-probes.txt`, ns/day, host clock). gbsa with its NonbondedForce dropped, so only the GB force remains, ran 1,040 to 1,148 on this branch against 1,244 to 1,323 on `metal`, 0.82 to 0.86x. With the GB force's cutoff turned off (`SPLIT_NOCUTOFF=1`) the same system ran 1,445 to 1,455 against 1,419 to 1,425, 1.02x. So HIP's GB kernels are as fast as `metal`'s, and the gap is in building and walking the neighbor list at gbsa's 2 nm cutoff. With NonbondedForce only, this branch is faster: 3,351 to 3,362 against 3,231 to 3,236.

HEAD's gbsa GB-only ranged 1,036 to 1,148 across runs, so a knob has to beat about 10 percent to show. None did: padding 0.1 (`metal`'s value) instead of HIP's 0.08, 4 to 32 tiles per batch, the force block shapes above, `__restrict__` removed, MSL 3.1, committing before the count download. Padding 0.15 gave 1,123 to 1,177 against HEAD's 1,069 to 1,106 in the same run, 5 percent, and I didn't take it further. Padding 0.05 lost about 11 percent. The list held 2,231 to 2,462 tiles with no single pairs. My hypothesis at the time was that HIP's findInteractingBlocks, with 32-thread threadgroups and 78 atom blocks, is latency-bound on 60 cores. The profile below rules that out: no kernel is slower in total, and the time goes to the GPU sitting idle while the host waits for the neighbor list count. NoCutoff has no count to wait for, which is why it came out even.

#### Profile on the M3 Ultra (owner at the machine)

The owner was using the Studio for light coding (bun, a dictation app) during these runs. Every run logs the 1 minute load average in its `loads.txt`, and I give the range with each set below.

Method. Only the Command Line Tools are installed, so there is no `xctrace` and no Metal System Trace. I timed the GPU with a lab-only header, `probes/GpuProf.h`, hooked into both trees by `probes/gbprof-hd.patch` and `probes/gbprof-ref.patch`. It has two modes. In `kernels` mode every dispatch is committed and waited on by itself, and I record its command buffer's GPUEndTime minus GPUStartTime. In `buffers` mode batching is left alone, and I record each command buffer's GPU start and end, its host commit time, the first and last kernel in it, and the host's waits. GPUStartTime and GPUEndTime are on the host's `mach_absolute_time` base, so GPU and host events share one clock. `probes/gbprof.py` builds the benchmark.py gbsa system (optionally without NonbondedForce, "GB only"), runs LangevinMiddle at 4 fs with 200 warm-up steps, and records a window of steps. Its step time is `time.perf_counter` around the window. Trees: this branch 9074c38f1 and `metal` 052eaa85b, each built in its own venv under `/tmp/openmm-metal-bench/gbsa-gap`.

Per kernel, `kernels` mode, 2,000 steps, round 1 of 3, full gbsa, GPU clock (`results/studio/gbsa-profile/prof1`, 1 minute load 4.6 to 11.7). One buffer per dispatch adds a floor of about 5 us to every kernel, so the totals are higher than a real step's GPU work.

| Kernel | Grid x threadgroup, this branch | us/step | Grid x threadgroup, `metal` | us/step |
|---|---|---:|---|---:|
| computeNonbonded | 2400x64 | 54.7 | 360x256 | 72.1 |
| computeGBSAForce1 | 720x64 | 52.1 | 360x256 | 51.0 |
| computeBornSum | 720x64 | 45.8 | 360x256 | 47.4 |
| computeBondedForces | 115x64 | 27.7 | 115x64 | 28.5 |
| findBlocksWithInteractions | 78x32 | 21.6 (median 4.75, max 299) | 10x256 | 10.4 (median 4.5, max 143) |
| sortBoxData | 39x64 | 16.5 | 39x64 | 6.2 |
| sortShortList2 / sortShortList | 2x64 | 8.7 | 1x256 | 10.8 |
| findBlockBounds | 78x32 | 6.3 | 2x64 | 11.9 |
| computeSortKeys | 2x64 | 4.6 | 2x64 | 5.3 |
| copyInteractionCounts | 1x1 | 3.7 | none | |
| reduceBornSum, reduceBornForce | 39x64 | 14.2 | 39x64 | 13.3 |
| integration, SHAKE, center of mass, clearing (9 kernels) | same | 55.7 | same | 52.8 |
| Total | 20.26 dispatches/step | 311.5 | 19.26 dispatches/step | 309.5 |

The three rounds gave totals of 311.5, 304.6 and 304.1 us/step on this branch and 309.5, 306.2 and 306.9 on `metal`. GB only: 292.0 to 296.1 against 286.4 to 288.2. So the GPU does the same work in both trees. The neighbor list kernels cost this branch about 61 us/step against `metal`'s 44, and the GB and nonbonded kernels give it back (153 against 170). The list runs every step in both trees; findBlocksWithInteractions returns early unless the rebuild flag is set, which is why its median is 4.5 to 4.75 us with occasional rebuilds of 140 to 300 us.

Per step, both trees commit 2 command buffers and do 1 host wait on the neighbor list count. Buffer X holds the integrator's first half and the list build and ends with the count event. Buffer Y holds the forces, starting with computeBornSum and ending with computeNonbonded. The host commits Y, then waits for X with `waitUntilCompleted()` and reads the count. `finish()` waits run 0.02 times per step.

Where the time goes, `buffers` mode, full gbsa, 3,000 steps per run, 2 interleaved rounds, step time on the host clock, gaps on the GPU clock (`results/studio/gbsa-profile/var3`, `var4`, 1 minute load 1.8 to 3.1):

| Variant | Step, us | Y starts after X ends, median us | Host wakes after X ends, median us |
|---|---:|---:|---:|
| This branch | 321.1 to 335.5 | 40.1 to 42.8 | 104.9 to 112.2 |
| `metal` | 284.1 to 286.4 | 0.4 | 89.8 to 94.2 |
| This branch, host spins on the event | 270.2 to 273.0 | 0.4 to 0.5 | 21.5 to 23.2 |
| This branch, spins, then `waitUntilCompleted()` | 312.9 to 319.9 | 38.2 to 38.8 | 99.1 to 99.6 |
| `metal`, host spins on the event | 278.0 to 280.1 | 0.5 | not recorded |
| `metal`, spins, then `waitUntilCompleted()` | 284.4 to 286.7 | 0.4 to 0.5 | 91.3 to 91.7 |

On this branch the GPU sits idle for about 40 us between X and Y every step, although the host committed Y about 160 us before X finished. The host commits late for only about 2 us per step. `metal` has no such gap. The Y buffer itself is faster here (medians of 178.8 to 180.3 us against 199.6 to 200.2 on `metal`), and X is the same (66.0 to 67.1 against 65.2 to 66.2), so without the gap this branch would beat `metal` on gbsa.

The gap follows the blocking wait. When the host spins on the shared event's `signaledValue` instead of sleeping in `waitUntilCompleted()`, Y starts 0.4 us after X and the step drops to 270 to 273 us, 5 percent faster than `metal`. Spinning until the signal and then calling `waitUntilCompleted()` brings the gap back, so it isn't the host arriving late; a thread blocked in `waitUntilCompleted()` on X delays the start of the Y that is already queued behind it. `metal` does the same blocking wait with no gap (see "Why `metal` has no gap" below). The gap stayed when I removed copyInteractionCounts (`HD_NOCOPY`), used 4 tiles per batch or 6 thread blocks per core (`var1`, 1 minute load 2.1 to 2.4, gap 37 to 40 us in every case). Committing after every force kernel (`var2`, `splitY`) let computeBornSum, alone in its buffer, start 0.4 us after X, and a 38 us median gap appeared before the next step's X instead.

Other observations. Skipping the wait and the count read entirely (`HD_NOWAIT`) removes the gap too, but the list then never grows past its initial 1,560 tiles, so Y skips work and the 169 to 171 us steps aren't valid. Profiling one kernel per buffer hides the gap, which is why the kernel totals match. An hd-only run with no `metal` runs interleaved (`prof3-*`, 1 minute load 4.6) sometimes had a small gap and 301 to 307 us steps, so its size varies between processes, but every interleaved comparison showed it.

#### Prototype: spin on the event

Local branch metal-hipdelta-gbsa in the worktree `/Users/amir/code/mini/hipdelta-gbsa`, one change to `MetalEvent::wait()`, not committed or pushed:

```cpp
    if (buffer != NULL)
        while (event->signaledValue() < value && buffer->status() < MTL::CommandBufferStatusCompleted)
            ;
```

The status check ends the loop if the command buffer fails before its signal, where `waitUntilCompleted()` would also have returned. HIP busy-waits here too: HipContext's `getEventFlags()` never sets `hipEventBlockingSync`, so `hipEventSynchronize` spins. delta.sh: 482 added lines in shared files and 1,900 in all of platforms/metal, against 479 and 1,897 at 9074c38f1, so 3 lines with the two comment lines.

Benchmark: `studio/gbsa-bench.sh`, benchmark.py `--platform Metal --precision single`, 3 interleaved rounds of 30 seconds, the tree order reversed every other round, ns/day on the host clock, owner at the machine (`results/studio/gbsa-profile/bench-spin`). The 1 minute load was 2.3 to 8.5 before every run, and it reached 16.7 during round 2's rf run on 9074c38f1, which is that tree's 571.7 outlier. Medians and ratios against `metal` 052eaa85b:

| Test | `metal` | 9074c38f1 | ratio | spin prototype | ratio |
|---|---:|---:|---:|---:|---:|
| gbsa | 1220.6 | 1037.3 | 0.850 | 1284.4 | 1.052 |
| rf | 707.8 | 637.6 | 0.901 | 736.2 | 1.040 |
| pme | 543.0 | 539.4 | 0.993 | 543.4 | 1.001 |
| apoa1rf | 287.6 | 300.7 | 1.045 | 301.4 | 1.048 |
| apoa1pme | 184.5 | 194.3 | 1.053 | 194.8 | 1.056 |
| apoa1ljpme | 129.0 | 144.2 | 1.118 | 145.6 | 1.129 |

The prototype passes the 0.97x gate on every test, and it fixes rf too, which the tiles-per-batch line only partly did. It costs host CPU: the thread that waits now spins instead of sleeping.

#### CPU cost, and waiting without spinning

The spin keeps a core busy for the whole wait. Folding@home users often run CPU work next to the GPU, and laptops run on battery, so I measured host CPU for several ways to wait. `probes/gbprof.py` reports the process's CPU time (`time.process_time`, all threads) over the timed window divided by the window's wall time (`time.perf_counter`), so 1.0 is one core busy the whole time. The wait mode is chosen at run time by `HD_WAIT` in `probes/GpuProf.h`'s `probeWait`. gbsa ran 5,000 steps and apoa1pme 1,000 steps without GPU records, 2 interleaved rounds each; the gap column comes from a separate `buffers` pass of 3,000 gbsa steps (`results/studio/gbsa-profile/wait1`, 1 minute load 1.8 to 3.5, owner at the machine).

| Wait | gbsa us/step | gbsa CPU cores | apoa1pme us/step | apoa1pme CPU cores | Y gap, median us |
|---|---:|---:|---:|---:|---:|
| `waitUntilCompleted()` (9074c38f1) | 313.8, 321.5 | 0.36 | 1776, 1778 | 0.07 | 40.0, 38.4 |
| `metal` 052eaa85b, `waitUntilCompleted()` | 282.0, 281.2 | 0.31, 0.33 | 1864, 1868 | 0.07 | 0.4, 0.5 |
| Spin on `signaledValue` | 269.1, 270.1 | 1.26, 1.29 | 1776, 1773 | 1.06 | 0.5, 0.4 |
| Spin at most 50 us, then `waitUntilCompleted()` | 320.7, 319.3 | 0.53, 0.54 | 1776, 1773 | 0.10 | 40.3, 39.6 |
| Spin at most 300 us, then `waitUntilCompleted()` | 274.1, 274.7 | 1.21, 1.20 | 1774, 1774 | 0.24 | 0.5, 0.5 |
| Poll with `usleep(10)` | 269.7, 270.8 | 0.46, 0.44 | 1771, 1775 | 0.15, 0.16 | 0.4, 0.5 |
| Poll with `usleep(50)` | 291.1, 292.5 | 0.44, 0.43 | 1772, 1773 | 0.10 | 0.5, 0.5 |
| Poll with `sched_yield()` | 269.5, 269.7 | 1.26, 1.25 | 1773, 1776 | 1.04 | 0.4, 0.5 |
| Poll with the ARM `wfe` instruction | 268.7, 268.9 | 1.28, 1.26 | 1784, 1776 | 1.05 | 0.5, 0.5 |
| `MTLSharedEvent::waitUntilSignaledValue()` | 279.1, 281.2 | 0.45, 0.44 | 1774, 1775 | 0.08 | 0.5, 0.5 |
| `MTLSharedEventListener` and a condition variable | 295.1, 294.4 | 0.47, 0.45 | 1774, 1771 | 0.08 | 0.5, 0.5 |
| `metal`, `waitUntilSignaledValue()` | 278.7, 277.2 | 0.30, 0.29 | 1867, 1864 | 0.07, 0.08 | 0.4, 0.5 |

Spinning costs a full core: 1.26 to 1.29 cores on gbsa against 0.36, and 1.06 on apoa1pme against 0.07, where it buys nothing because apoa1pme's GPU work dwarfs the wait. `sched_yield()` and `wfe` cost the same as the plain spin. A short bounded spin doesn't help: the host starts waiting about 160 us before X finishes, so a 50 us bound always falls through to `waitUntilCompleted()` and the gap comes back, and a bound long enough to cover the wait is a spin again. Polling every 10 us matches the spin's speed at a third of its CPU on gbsa, but doubles the CPU on apoa1pme.

The fix I'd take is `waitUntilSignaledValue()` on the shared event the tree already signals. The host sleeps, the gap is gone, gbsa matches `metal` (279 to 281 us against 281 to 282), and apoa1pme's CPU stays at 0.08 cores. On gbsa it uses 0.44 cores against the blocking wait's 0.36 and `metal`'s 0.31 to 0.33, partly because steps come faster: per step that is about 125 us of CPU against 114 and 90. The call exists since macOS 12 (`API_AVAILABLE(macos(12.0))` in the SDK's MTLEvent.h). Anukari's developer found the same thing on Apple's advice: waiting on an MTLSharedEvent had much lower latency than `waitUntilCompleted` ([Huge macOS performance improvements](https://anukari.com/blog/devlog/huge-macos-performance-improvements)). `metal` gains a little from it too, 277 to 279 against 281 to 282 us.

#### Why `metal` has no gap

I compared what the two trees do at run time, not only their source. Every host-side step is the same (`probes/gbprof-xy.py` on `var4`, `probes/gbprof-scheduled.py` on `wait1`, 3,000 gbsa steps each, medians):

- Both wait on X, the buffer that ends with the count event, and nothing later.
- Both commit Y before the wait: Y's commit is 161.0 us before X's GPU end on this branch and 161.5 us before it on `metal`, and the wait starts about 1 us after Y's commit.
- Both use `waitUntilCompleted()` on the command buffer, with no MTLSharedEventListener and no notify.
- Both create the queue with a plain `newCommandQueue()` (default maximum of 64 command buffers) and buffers with a plain `commandBuffer()` (retained references, default error options). Neither tree uses a command buffer descriptor.
- X ends the same way in both: a compute encoder, then `encodeSignalEvent`, with no blit.
- The Metal calls each tree makes are the same set, apart from the reflection calls this branch uses to read kernel argument sizes and `metal`'s `threadExecutionWidth` query.
- Metal reports Y as scheduled (`addScheduledHandler`) 103 us before X's end on this branch and 124 us before it on `metal`, so Y reaches the GPU in time in both.

So nothing in the queue or buffer settings is different, and there is no setting to copy. On this branch the stall sits between Y being scheduled and Y starting on the GPU, and it happens only while a thread is blocked in `waitUntilCompleted()`. It also depends on what the buffer after X holds: computeBornSum alone started on time. My guess is that the driver's completion path for a waited-on buffer holds up the next buffer longer when that buffer is larger or binds more resources. I haven't tested that. Instruments' Metal System Trace, which needs full Xcode on the Studio, would show it. Either way, waiting on the event doesn't depend on the cause.

#### Second prototype: wait on the event

Same worktree and branch, replacing the spin (the spin's diff is `results/studio/gbsa-profile/bench-spin/spin.patch`):

```cpp
    if (buffer != NULL)
        while (!event->waitUntilSignaledValue(value, 100) && buffer->status() < MTL::CommandBufferStatusCompleted)
            ;
```

The 100 ms timeout and the status check make the loop return if the buffer fails before its signal, where `waitUntilCompleted()` would also have returned. delta.sh: 482 added lines in shared files and 1,900 in all of platforms/metal, 3 more than 9074c38f1, two of them the comment.

Committed as 6df2b8bcb on branch metal-hipdelta-gbsa (pushed to `mini` only). Against `metal` 052eaa85b on the M3 Ultra, 3 interleaved rounds of 30 seconds, host clock, owner at the machine, 1 minute load about 2.3 to 3.4 (`results/studio/gbsa-profile/bench-wait`, `summary.txt`):

| Test | `metal` ns/day | 6df2b8bcb ns/day | Ratio |
|---|---:|---:|---:|
| gbsa | 1229.2 | 1264.3 | 1.029 |
| rf | 718.7 | 725.8 | 1.010 |
| pme | 544.1 | 541.4 | 0.995 |
| apoa1rf | 288.2 | 301.6 | 1.046 |
| apoa1pme | 184.3 | 193.6 | 1.051 |
| apoa1ljpme | 129.5 | 145.1 | 1.120 |

Every test clears the 0.97 gate, which 9074c38f1 failed on gbsa (0.850) and rf (0.901) in the spin run. Forces against Reference are unchanged: rel|dF| is identical to 9074c38f1 on all six systems and rel|dE| moves within run-to-run noise (`results/studio/gbsa-profile/forces-wait`). The spin reached 1.052 on gbsa; the event wait gives up about 2 percent of that for no busy core. The profiling agent ended before writing this table; the lead computed it from the raw rounds with `summarize.py`.

### M2 gates for 6df2b8bcb

On the M2 (`results/m2-eventwait`):

- ctest: 109 of 110 pass. TestMetalLangevinIntegratorMixed failed once ("Expected 9.97736, found 10.8367", a check the test marks stochastic), then passed 5 of 5 on the branch and 5 of 5 on the parent, interleaved.
- Forces against Reference: rel|dF| 2.0e-05 to 7.7e-05 on all six systems, the same as 9074c38f1.
- TestMetalMonteCarloFlexibleBarostat, single precision, 5 runs each: the branch passes 4, `metal` 052eaa85b (`~/lab/hipdelta-ref`) passes 5. The test is statistical and `metal` has failed it 1 in 5 before (stage 4 row above), so this is not a signal yet. A 10-run repeat on the M3 Ultra is running, with three arms: 6df2b8bcb, its parent 9074c38f1, and 052eaa85b.
- Speed against `metal` 052eaa85b, median of 3 rounds of 30 s, host clock. The run did not record its nice value, and zsh starts background jobs over ssh at nice 5, so the absolute ns/day may be niced. Both builds ran interleaved in the same process tree, so the ratios compare like with like:

| Test | `metal` | 6df2b8bcb | Ratio |
|---|---:|---:|---:|
| gbsa | 384.8 | 412.6 | 1.072 |
| rf | 253.2 | 254.5 | 1.005 |
| pme | 199.8 | 207.2 | 1.037 |
| apoa1rf | 58.9 | 69.2 | 1.175 |
| apoa1pme | 47.0 | 54.4 | 1.156 |
| apoa1ljpme | 33.9 | 40.0 | 1.181 |

The M2 gains are larger than the M3 Ultra's on the big systems. The small ones stay near parity on both machines.

### The apoa1ljpme spread was a bug

`metal` 052eaa85b ran apoa1ljpme at 128.4 to 129.6 ns/day over 5 fresh processes. This branch ran 157.9, 157.7, 157.0, 88.0 and 156.7 (`results/studio/screen-apoa1ljpme-spread`, 15 seconds each, host clock, 1 minute load 2.6 to 5.8). Earlier runs had also given 44 to 53 and 72 to 99. So the spread is ours.

Narrowing it down, all with `probes/split.py`:

- The speed is fixed for the life of a context. Chunks within a process agree within 10 percent, and processes differ by up to a factor of 2.6.
- It is GPU time. The host thread used 1 to 12 percent of wall time in fast and slow processes alike.
- apoa1rf never showed it: 297.8 to 301.5 in 6 processes. apoa1ljpme without NonbondedForce ran 1,462 to 1,489 in 6. So it's PME.
- apoa1pme with reciprocal space only (`SPLIT_RECIPONLY=1`) made it plain: 155 to 397 ns/day across processes, against 372 to 375 for `metal` in 2 processes. A null FFT, `metal`'s FFT settings, no PME spreading, 24 thread blocks per core and the post-force commit all left a slow process in each set.
- Skipping the PME atom sort removed it: 6 of 6 at 384 to 388. That points at `MetalSort`.

PME sorts its 92,224 atoms with the bucket sort, since the list is longer than the 1,024 the single-kernel sort takes. HIP's `computeRange` splits the range search over `length/rangeKernelSize` threadgroups, and whichever finishes last reduces the partial ranges. That reads other threadgroups' device-memory writes inside the same dispatch, after a `__threadfence()`. MSL doesn't promise those are visible without `coherent(device)` buffers. My reading is that a stale minimum or maximum gives wrong bucket widths, which pile atoms into a few buckets and make the later sort kernels slow without breaking the order. I didn't dump the buckets to confirm it, and I don't know why a process keeps one mode for its lifetime. The evidence is the fix: with no cross-threadgroup reduction the spread is gone. `metal` runs this kernel as one threadgroup.

9074c38f1 sets `rangeKernelBlocks = 1`, 1 line. Then 8 of 8 reciprocal-only processes ran at 367 to 372 ns/day. That is 2 percent below `metal`'s 372 to 375, since one threadgroup now scans all 92,224 keys. The 395 of the fast processes before the fix isn't a speed to hold against it: those processes ran on whatever range the race left them. benchmark.py confirms it (`studio/screen.sh`, 5 rounds of 15 seconds in fresh processes, host clock, 1 minute load 2.4 to 8.4, `results/studio/screen-rangefix`):

| Test | `metal` 052eaa85b | 5d9e2388e | 5d9e2388e with one range threadgroup |
|---|---|---|---|
| apoa1ljpme | 128.1 to 129.0 | 156.1, 59.3, 156.4, 156.4, 67.9 | 143.6 to 143.9 |
| apoa1pme | 182.7 to 184.1 | 156.4, 197.7, 199.4, 167.3, 199.7 | 191.1 to 193.7 |

With the fix both systems are steady at 1.05 to 1.12x `metal`. That is this branch's honest number on the M3 Ultra. The earlier 156 to 158 ns/day on apoa1ljpme, and the 1.217 ratio in the stage 2 table, came from the race: computeRange read stale values, and a process ran fast or slow depending on the range it got. Neither is a speedup the code can keep.

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
- Fast math mode, HIP's own setting (stage 3). 2 to 2.6 percent faster on the M2, but the constant potential solve stops converging.

## Review findings not fixed

A read-only review of the stage 2 diff found these. None changes forces in the tests.

- CCMA: the host resets the converged flag by writing shared memory, while the tail iterations of the previous solve can still be in the open command buffer. The verifier's reading narrows it: it needs more than 1,024 constraints (below that CCMA runs as one kernel) and a solve that hits the 150-iteration cap while converging at iteration 147 or 148. The result is one step with loose constraints. HIP has the same race with an async stream. Command batching makes it more likely. `metal` avoids it by reading `ccmaConverged` instead. Not changed, to stay with HIP.
- sort.metal: the last-block reduction in `computeRange` reads other threadgroups' results with plain loads. `__threadfence()` orders them, but MSL only guarantees cross-threadgroup visibility for `coherent(device)` buffers. A stale value makes uneven buckets, which costs speed, not order, as long as every key still lands in a bucket. A key below a stale minimum makes a negative quotient, which `assignElementsToBuckets` converts to `unsigned int`. If Apple GPUs don't saturate that conversion to 0, the key goes to the last bucket and the order breaks. Experiment 021 found float to long conversions wrap on the M3. Round 2 found the stale reads in practice on the M3 Ultra, as a speed loss, and 9074c38f1 removes the cross-threadgroup reduction. The other sort kernels only read other threadgroups' writes in a later dispatch, where Metal guarantees them.
- `__launch_bounds__` expands to nothing, and `executeKernelFlat` doesn't check the block size against the pipeline's limit. `computeBucketPositions` can ask for 1024 threads.

## Risks of the cut

- A machine with no `AGXAccelerator` service in the IORegistry, such as a VM, throws "Error initializing Metal: the IORegistry has no GPU core count" (5d9e2388e). The cut had left a NULL dereference there. `metal` falls back to 8 cores and runs.
- Apple GPUs run 32-wide SIMD groups. On a GPU that didn't, the kernels would compute wrong results instead of throwing.
- A NULL shared event or command queue crashes at its next use instead of throwing.
- `MetalEvent::wait` no longer checks its command buffer for an error. The queue reports a failed buffer at its next commit or finish.
- Mixed precision covers what `metal`'s df64 covers. A custom force or integrator that calls sin, cos, pow or the other deleted functions on a mixed value fails to compile in mixed precision, as QTBIntegrator does. Double precision stays unsupported.
- The minimizer's mixed precision reductions run in one thread block of `getMaxThreadBlockSize()` threads. Only mixed precision takes that path. I didn't time it against single precision's atomics.
- `std::regex` costs little: the M2 ctest took 236 s against 234 s for aa7464387 (`results/ctest-stage2-min.txt`, `results/ctest-stage2-final.txt`).

## Files

- `delta.sh`: the metric.
- `leased.sh`: holds the mini lease around one command.
- `studio/`: the M3 Ultra versions of build, ctest, bench and the lease wrapper. They work under `/tmp/openmm-metal-bench/hipdelta`, with a venv per tree.
- `forces.py`: Metal against Reference.
- `bench.sh`, `summarize.py`: interleaved benchmark rounds and their medians.
- `screen.sh`: one benchmark round per setting of temporary environment knobs.
- `ab.sh`: interleaved rounds of several variants on the mini, each a tree plus environment settings. `PRECISION` sets the precision.
- `studio/screen.sh`: one benchmark run per knob setting on the Studio.
- `STATE.md`: where the unattended run stands, for a restart.
- `install.sh`, `final.sh`: rebuild and install on the mini, then ctest, forces, the FlexibleBarostat repeats and the benchmark.
- `probes/split.py`: builds one benchmark system, optionally drops force classes, turns off cutoffs or direct space, and times chunks in fresh contexts. Round 2 used it to split gbsa and to find the apoa1 sort bug.
- `results/studio/screen-m3-1`, `screen-m3-2`, `screen-apoa1ljpme-spread`, `split-probes.txt`, `results/m2-tiles`: round 2 logs.
- `probes/`: MSL compile probes and `mslc.swift`, the compiler driver (`swiftc -O mslc.swift`). `rewriter-compare.cpp` runs the old and new signature rewriters over kernel files. `chunks.py` times an apoa1 system in 200-step chunks. `rfdebug.py` shows the exception benchmark.py hides. `edge.py` tries Mixed and Double precision and `DeviceIndex` "0,0". `fastacc.swift` runs `metal`'s fast math accuracy check and a wider sweep.
- `probes/GpuProf.h`, `probes/gbprof-hd.patch`, `probes/gbprof-ref.patch`: the lab-only GPU timer and the diffs that hook it into each tree, with the temporary knobs used in the gbsa profile (`HD_SPLIT`, `HD_NOCOPY`, `HD_NOWAIT`, `HD_TILES`, `HD_TBPC`, and `HD_WAIT`, which picks the wait mode in `probeWait`). `HD_SPIN`, used for `var3` and `var4`, became `HD_WAIT=spin` and `HD_WAIT=spinwait`.
- `probes/gbprof.py`: runs one benchmark.py system and records a window of steps. `gbprof-summary.py` prints the per-kernel table and buffer busy time, `gbprof-boundaries.py` the GPU idle time before each buffer grouped by the kernels on either side, `gbprof-gaps.py` the X to Y gap and the host's wake time, `gbprof-xy.py` each step's commit, wait and start times around X, `gbprof-scheduled.py` when Metal reports each buffer scheduled.
- `studio/gbsa-build.sh`, `gbsa-leased.sh`, `gbsa-profile.sh`, `gbsa-variants.sh`, `gbsa-bench.sh`: the gbsa profile's build, lease, profiling runs and benchmark rounds under `/tmp/openmm-metal-bench/gbsa-gap`.
- `results/studio/gbsa-profile/`: the gbsa profile's records (gzipped), summaries, `loads.txt` per set, and the prototype's benchmark rounds.
- `results/`: raw logs.

# 024: Metal as the smallest diff from HIP

peastman plans to write the Metal platform himself, starting from CUDA or HIP, and to read ours as a reference. So the product here is a readable "HIP to Metal in N lines" diff. Every line that differs from HIP should exist because Metal needs it or because it measurably speeds things up.

The OpenMM branch is `metal-hipdelta` on the `mini` remote, from merge base 3c9effc96. The comparison build is `metal` at 361452c5c. Stage 2 is commits 495350e28 (HIP's nonbonded kernels), 24c34d794 (tuning) and aa7464387 (a destructor fix from review). Stage 3 and stage 4 wait for the lead.

## Metric

`delta.sh <repo> [ref]` copies `platforms/hip`, renames Hip to Metal and `.hip` to `.metal`, and counts the lines `diff -w` adds in each shared file. It also lists files that exist only in Metal. It counts `src`, `src/kernels` and `include`. CMake files and tests are not counted.

| Build | Added lines in shared files | Metal-only lines | Total |
|---|---:|---:|---:|
| `metal` 361452c5c (baseline) | 2,024 | 697 (df64 683, utilities 14) | 2,721 |
| Stage 1: host layer, `metal` nonbonded kept | 1,340 | 0 | 1,340 |
| Stage 2: HIP nonbonded and neighbor list kernels, 495350e28 | 716 | 0 | 716 |
| Stage 2 plus tuning, 24c34d794 | 723 | 0 | 723 |
| Stage 2 plus the destructor fix, aa7464387 (HEAD) | 731 | 0 | 731 |

Without df64 the baseline is 2,038. Stage 2 is single precision only, so it has no mixed precision to compare with df64. Logs: `results/delta-*.txt`.

## Delta per file at HEAD

| File | Added | Why |
|---|---:|---|
| src/MetalContext.cpp | 241 | Kernel signature rewriter, 100 lines: pointer parameters get `device`, value parameters become `constant T&` plus a prologue copy, `thread` is renamed because MSL reserves it, `long long` becomes `long`. Reflection in getKernel records which arguments go by value, 30 lines. launchKernel encodes into the queue's open encoder with setBuffer or setBytes, 18 lines. Library compile with MSL 3.2 and safe math, 25 lines. GPU core count from the IORegistry, 20 lines, because Metal doesn't report it. Tuning: `fast::divide` for RECIP, 12 thread blocks per core. |
| src/kernels/common.metal | 138 | CUDA names for MSL built-ins (program-scope `threadIdx` and friends, `__syncthreads`, `__threadfence`, `__shared__`), atomics (MSL has no 64 bit atomic add on the M1 and M2, and no float atomic min or max), `make_` vector macros, `f` suffix math names, erf and erfc (MSL has neither), half conversions, realToFixedPoint without `long long`. HIP's `__expf`, `__logf`, `__frsqrt_rn` and `__fsqrt_rn` mapped to MSL's fast and precise functions. |
| src/MetalQueue.cpp | 83 | One open command buffer and compute encoder per queue, committed at upload, download and step boundaries, with error checks. The destructor skips failed buffers instead of throwing. |
| include/MetalQueue.h | 55 | Declarations for the above. |
| src/MetalPlatform.cpp | 33 | macOS 15 and GPU family Apple7 check, device name through metal-cpp, one device, PME stream off by default. |
| src/MetalFFT3D.cpp | 25 | VkFFT's Metal backend, encoding into the open encoder. |
| src/MetalEvent.cpp | 23 | MTLSharedEvent signal and wait. |
| include/MetalContext.h | 23 | Host vector typedefs (`int2`, `float4`, `uint1`) that HIP gets from its runtime headers, metal-cpp handles. |
| src/MetalArray.cpp | 20 | Shared storage buffers, so upload and download finish the queue and then memcpy. copyTo is a blit in the open command buffer. |
| src/kernels/intrinsics.metal | 15 | `warpSize`, 64 bit shuffles as two 32 bit halves, `__shfl`, `__shfl_down`, `__ballot` on simd_ functions. |
| src/MetalNonbondedUtilities.cpp | 14 | Shared buffer for the interaction count, ComputeEvent, commit before waiting on the count. Tuning: 40 force thread blocks per core, one tile per batch. |
| src/kernels/sort.metal | 10 | `extern __shared__` becomes a `[[threadgroup(0)]]` parameter, `__threadfence()` before the last-block reduction. |
| src/kernels/findInteractingBlocks.metal | 15 | See kernel rewrites below. |
| other 10 files | 36 | Handle typedefs, includes, ComputeEvent members, the commit after the force computation. |
| src/kernels/nonbonded.metal | 0 | HIP's kernel compiles unchanged. |

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

ctest on the M2 mini, `-R TestMetal`, 2 jobs, 600 s timeout.

| Build | Result |
|---|---|
| `metal` 361452c5c, Single | 55/55 pass |
| Stage 1, Single | 54/54 pass |
| Stage 2 untuned, Single | 54/54 pass |
| Stage 2 HEAD aa7464387, Single | 54/54 pass |

The one test `metal` has and this branch doesn't is TestMetalMixedPrecisionSingle, dropped with mixed precision. The pass sets match otherwise. Logs: `results/ctest-*.txt`.

In one stage 2 run TestMetalMonteCarloFlexibleBarostatSingle failed next to the two GB tests that didn't compile yet. It passed when rerun alone and in the next full run. It is a statistical test of the volume distribution. Run 5 times in a row, it failed once on this branch and twice on `metal` (`results/flexible-stage2-final.txt`). It is flaky on both, not a regression.

## Forces against Reference

`forces.py` builds the benchmark.py systems, evaluates forces and energy once on Metal single and once on Reference, and prints relative force error, largest component error and relative energy error. Logs: `results/forces-stage2.txt` (untuned, and `metal`), `results/forces-stage2-final.txt` (HEAD).

| Test | Atoms | HEAD rel\|dF\| | `metal` rel\|dF\| | HEAD rel\|dE\| | untuned rel\|dE\| | `metal` rel\|dE\| |
|---|---:|---:|---:|---:|---:|---:|
| gbsa | 2,489 | 2.467e-05 | 2.467e-05 | 5.5e-07 | 1.8e-07 | 5.4e-07 |
| rf | 23,558 | 2.213e-05 | 2.213e-05 | 2.2e-07 | 2.4e-07 | 2.3e-07 |
| pme | 23,558 | 2.048e-05 | 2.048e-05 | 1.2e-06 | 1.1e-06 | 1.3e-06 |
| apoa1rf | 92,224 | 5.987e-05 | 5.987e-05 | 1.2e-07 | 5.4e-08 | 9.5e-08 |
| apoa1pme | 92,224 | 7.747e-05 | 7.747e-05 | 7.6e-07 | 5.4e-07 | 7.8e-07 |
| apoa1ljpme | 92,224 | 7.747e-05 | 7.747e-05 | 1.0e-06 | 5.3e-07 | 1.1e-06 |

Force errors agree with `metal` to four digits, before and after tuning. The fast math functions bring the energy errors close to `metal`'s. `metal` switches to the same fast functions when a runtime accuracy check passes. apoa1rf is 1.2e-7 against 9.5e-8. The apoa1 systems have more than 90,000 atoms, so they also cover the large block path of the neighbor list.

## Benchmarks

`bench.sh` runs `examples/benchmarks/benchmark.py --platform Metal --precision single` on this branch and on `metal` 361452c5c, alternating which goes first in each round. benchmark.py times with the host clock: `datetime.now()` around `step()`, with a `getState()` to sync. Numbers are ns/day on the M2 mini, median of 3 interleaved rounds of 30 seconds.

HEAD aa7464387 (`results/bench-stage2-final`):

| Test | `metal` | HEAD | Ratio | `metal` rounds | HEAD rounds |
|---|---:|---:|---:|---|---|
| gbsa | 387.3 | 418.4 | 1.081 | 387.9 384.5 387.3 | 419.3 418.4 413.8 |
| rf | 253.9 | 253.7 | 0.999 | 255.3 253.9 253.9 | 254.2 253.7 253.2 |
| pme | 199.8 | 208.1 | 1.042 | 200.4 199.7 199.8 | 208.4 208.1 207.9 |
| apoa1rf | 59.0 | 69.3 | 1.174 | 59.0 59.0 59.0 | 69.2 69.3 69.4 |
| apoa1pme | 46.9 | 54.5 | 1.162 | 47.1 46.9 46.9 | 54.5 54.4 54.5 |
| apoa1ljpme | 33.9 | 40.5 | 1.193 | 33.9 33.9 33.9 | 40.5 40.5 40.4 |

Rounds vary by 1 percent or less. rf ties. Everything else is 4 to 19 percent faster than `metal`.

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
- HIP's default of a separate PME stream made 4.01 command buffer commits per PME step against the test's limit of 2.1. Each event between the queues commits a buffer. `DisablePmeStream` now defaults to true.
- `&blockSizeRange->x` fails in MSL (probe3.metal, "address of vector element requested").
- `thread unsigned int&` in a kernel file fails because the rewriter renames `thread`. `PRIVATE` works.
- `simd_shuffle` and `simd_shuffle_rotate_down` reject 64 bit types, which the GB kernels shuffle. Overloads split them into two 32 bit halves.
- MSL rejects `long long`, `max(0, uint)` and a redefined `FLT_MAX` (probe2.metal). `__threadfence()` needs MSL 3.2's `thread_scope_device`.
- HIP's kernels as ported ran at 0.55 to 0.86 of `metal` on the small systems. Safe math mode makes HIP's plain `1.0f/x` a precise divide, and HIP's thread block counts are sized for AMD compute units. See the tuning table.
- `MAX_BITS_FOR_PAIRS` 0 (no single pairs) and `metal`'s 256-thread force blocks were slower than HIP's defaults.

## Review findings not fixed

A read-only review of the stage 2 diff found these. None changes forces in the tests.

- CCMA: the host resets the converged flag by writing shared memory, while the tail iterations of the previous solve can still be in the open command buffer. After a solve that runs all 150 iterations, a stale kernel can set the flag and end the next solve early. HIP has the same race with an async stream. Command batching makes it more likely. `metal` avoids it by reading `ccmaConverged` instead. Not changed, to stay with HIP.
- sort.metal: the last-block reduction in `computeRange` reads other threadgroups' results with plain loads. `__threadfence()` orders them, but MSL only guarantees cross-threadgroup visibility for `coherent(device)` buffers. A stale value makes uneven buckets, which costs speed, not order.
- `__launch_bounds__` expands to nothing, and `launchKernel` doesn't check the block size against the pipeline's limit. `computeBucketPositions` can ask for 1024 threads.

## Files

- `delta.sh`: the metric.
- `leased.sh`: holds the mini lease around one command.
- `forces.py`: Metal against Reference.
- `bench.sh`, `summarize.py`: interleaved benchmark rounds and their medians.
- `screen.sh`: one benchmark round per setting of temporary environment knobs.
- `install.sh`, `final.sh`: rebuild and install on the mini, then ctest, forces, the FlexibleBarostat repeats and the benchmark.
- `probes/`: MSL compile probes and `mslc.swift`, the compiler driver (`swiftc -O mslc.swift`).
- `results/`: raw logs.

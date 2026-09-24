# Apple GPU and Metal, low-level brief for experiment 028

Research lane, 2026-09-24. This is for the implementation lanes: dispatch overhead, atomics, nonbonded, PME/FFT, mixed precision and plugins. The target is the M3 Ultra (Apple9, 60 GPU cores, macOS 27.2). The code base is 6df2b8bcb.

Each claim carries a tier. **Verified** means I read the primary source or our code and cite it. **Lab** means one of our experiments measured it, and I name the experiment. **Reported** means a source says it and I didn't check. **Inference** is my own reasoning. Nothing in this brief was built or run for it.

## The short answer

Metal single runs at 1.02 to 1.13x OpenCL single on benchmark.py today (lab 025, M3 Ultra, host clock). The reason is structural. Both APIs compile the same translated kernels through Apple's AGX backend, and a pipelined OpenCL queue submits as cheaply as Metal (lab 008). A speedup has to come from things Apple's OpenCL 1.2 can't do, and I count four of them:

1. Hardware float atomics on Apple9 for PME spreading.
2. Overlapping independent GPU work: a second queue for PME, and concurrent dispatch inside the step.
3. Fewer dependent dispatches per step, since every serial dispatch costs about 1.9 us of GPU time on the M3 Ultra.
4. MSL 4.1 features: threadgroup float atomics and acquire/release atomics, which make single-pass reductions possible.

Metal 4, indirect command buffers, df64 tricks and FFT replacements are second order for benchmark.py. I don't see a path to 4x. My estimate for the four levers stacked is 1.3 to 1.6x on the PME tests and 1.2 to 1.4x on gbsa and rf (inference).

## Where the step time goes, for scale

benchmark.py runs at 4 fs (benchmark.py:326). At the 025 medians that gives these step times (arithmetic on lab 025 numbers):

| test | Metal single ns/day | us/step |
|---|---:|---:|
| gbsa | 1272.6 | 272 |
| rf | 717.6 | 482 |
| pme | 542.2 | 637 |
| amber20-dhfr | 577.1 | 599 |
| apoa1pme | 194.7 | 1775 |
| amber20-cellulose | 54.4 | 6358 |

Lab 024 profiled gbsa at 20.3 dispatches per step, 2 command buffers per step and one host wait on the neighbor-list count (`MetalNonbondedUtilities.cpp:450-451`). Most kernels launch 39 to 720 threadgroups of 64 threads. Apple's rule of thumb is 1K to 2K threads per core, 60K to 120K threads on this GPU ([WWDC22 10159](https://developer.apple.com/videos/play/wwdc2022/10159/)). The 39x64 integration kernels fill about 2% of the machine. The small tests are latency bound and the big ones are throughput bound, so different levers matter for each.

## 1. Command submission

### Costs we measured (lab 008, M3 Ultra)

| Pattern | Host encode, us per dispatch | GPU time, us per dependent dispatch |
|---|---:|---:|
| One command buffer per kernel | 15.1 | 3.5 |
| One serial encoder, N dispatches | 0.112 | 1.88 |
| One concurrent encoder, barrier after every dispatch | 0.286 | 2.33 |
| Metal 4, one encoder, argument table, intra-pass barriers | 0.100 | 2.16 |
| Metal 4, one encoder per kernel, queue barriers | 1.03 | 14.4 |
| OpenCL, batched | 0.385 | 2.27 |

Other lab numbers:

- metal-cpp costs the same as Objective-C, within 3 ns per call (008).
- A blocking wait (`waitUntilCompleted`, or `waitUntilSignaledValue` with a timeout) wakes the host 90 to 110 us after the GPU signals. Spinning on `signaledValue` wakes it in 22 us (lab 024, gbsa).
- A thread blocked in `waitUntilCompleted()` on buffer X delayed the start of the already-committed buffer Y by about 40 us. 6df2b8bcb fixes that by waiting on the shared event (`MetalEvent.cpp:51-57`).

What this means (inference): the host is not the bottleneck once a step sits in one or two command buffers. The GPU-side cost of about 1.9 us per dependent dispatch is. On gbsa that is about 38 us of a 272 us step. A barrier costs the same wherever it comes from, whether an encoder boundary, a serial dispatch or `memoryBarrier`, so the lever is to have fewer of them.

### Serial vs concurrent dispatch (classic Metal)

- Verified. `MetalQueue::getEncoder` calls `computeCommandEncoder()` with no argument (`MetalQueue.cpp:47`), which gives `MTLDispatchTypeSerial`. Every dispatch waits for the previous one to finish. metal-cpp exposes `computeCommandEncoder(MTL::DispatchType)` (`MTLCommandBuffer.hpp:152`), `memoryBarrier(BarrierScope)` and `memoryBarrier(resources, count)` (`MTLComputeCommandEncoder.hpp:77-78`).
- Reported by Apple ([WWDC22 10159](https://developer.apple.com/videos/play/wwdc2022/10159/)): with `MTLDispatchTypeConcurrent`, "barriers must be put in manually". It lets the driver "pack the work more tightly, hiding most of the synchronization cost between dependent kernels, as well as fill the ramp up and tail end". Apple's example ran 30% faster with two independent images interleaved and 70% faster with three, and concurrent dispatch "greatly improved ... scaling when moving from M1 Max to M1 Ultra".
- Inference, and the design I'd test first. Every force kernel only adds into the same fixed-point force buffer through atomics, and those adds commute. So bonded, nonbonded, GB and custom forces need no barrier between them. They need one barrier after the last force kernel and before the reduction or integration that reads forces. Within a chain (computeBornSum, reduceBornSum, computeGBSAForce1, reduceBornForce) keep barriers. A simple rule for MetalQueue: open a concurrent encoder, give each kernel a flag saying whether it needs a barrier before it, and default to true. Lab 008 shows that a barrier on every dispatch costs 0.45 us more than a serial dispatch, so the default path loses a little and the force section gains.
- Caution (inference). I found no Apple statement on whether `memoryBarrier(resources:)` in a concurrent encoder waits only on writers of those resources or on every prior dispatch. Assume every prior dispatch until a probe shows otherwise. That means two interleaved dependency chains in one encoder run in lockstep, which is why PME wants its own queue.

### A second queue for PME

- Verified. `MetalDisablePmeStream` defaults to "true" (`MetalPlatform.cpp:137`), so `usePmeQueue` is false and reciprocal PME runs in series with the nonbonded kernel (`MetalKernels.cpp:51`). `MetalContext::createQueue` makes a new `MTLCommandQueue` (`MetalContext.cpp:535-536`), and `MetalEvent::queueWait` encodes a cross-queue wait (`MetalEvent.cpp:59-63`). So the pieces exist.
- Verified. CUDA and HIP run PME on a separate stream by default. HIP disables the stream only for CPU PME (commit a29596c70, #3148).
- Reported ([WWDC22 10159](https://developer.apple.com/videos/play/wwdc2022/10159/)): "If work can't be encoded in advance on the same queue, consider using a second queue to overlap work."
- Lab. On the M3 Ultra the translated reciprocal pipeline takes about 0.76 ms at ApoA1 size (lab 011), against a 1.775 ms apoa1pme step.
- Inference. With PME on a second queue, each step needs 2 more command buffers and 2 event waits. The host side costs about 15 us per extra buffer (lab 008) and is off the critical path. The GPU side is unknown. FAH cores force DisablePmeStream=1 (research/2026-09-23-fah-core-requirements.md), so this helps benchmark.py and not FAH.

### Metal 4 for compute

- Verified. Metal 4 needs macOS 26 or later and GPU family Apple7 or later, so M1 and newer ([Feature Set Tables](https://developer.apple.com/metal/Metal-Feature-Set-Tables.pdf), footnote 1: "the Metal 4 programming model is available as of Apple7"; [MTL4CommandQueue](https://developer.apple.com/documentation/metal/mtl4commandqueue) is available from macOS 26.0). The vendored metal-cpp at `libraries/metal-cpp` is the "macOS 27, iOS 27" release (README changelog) and ships every MTL4 header: CommandQueue, CommandBuffer, CommandAllocator, ComputeCommandEncoder, ArgumentTable, Counters, CommitFeedback and more.
- Verified ([Understanding the Metal 4 core API](https://developer.apple.com/documentation/metal/understanding-the-metal-4-core-api)):
  - Command buffers come from the device and can be reused through `beginCommandBuffer(allocator:)`, and they don't retain resources.
  - Encoders bind through `MTL4ArgumentTable` instead of per-encoder `setBuffer`.
  - "In Metal 4, the framework considers all resources untracked", so every hazard needs an explicit barrier.
  - `MTL4ComputeCommandEncoder` merges the compute, blit and acceleration-structure encoders.
  - `MTLEvent` and `MTLSharedEvent` synchronize any mix of MTL and MTL4 queues, so we can adopt Metal 4 one piece at a time.
- Lab 008: MTL4 dispatches are concurrent by default. Serial order needs `barrierAfterEncoderStages(Dispatch, Dispatch, ...)`. Host encode is 0.100 us, the same as classic, and GPU time per dependent dispatch is 2.16 us, a little worse than classic serial.
- Verified in the headers. Two Metal 4 compute features that classic Metal lacks in this form:
  - `dispatchThreadgroups(MTL::GPUAddress indirectBuffer, threadsPerThreadgroup)` (`MTL4ComputeCommandEncoder.hpp:83`) reads its grid from a GPU address.
  - `executeCommandsInBuffer(icb, MTL::GPUAddress indirectRangeBuffer)` (`:89`) runs an ICB range that the GPU wrote.

  Classic Metal already has `dispatchThreadgroups(indirectBuffer, offset, ...)` (`MTLComputeCommandEncoder.hpp:68`) and `executeCommandsInBuffer(icb, indirectRangeBuffer, offset)` (`:75`), so neither one needs Metal 4.
- Verdict (inference). Don't port the platform to Metal 4 for speed. The one strong reason to use MTL4 is timing (section 6).

### Residency sets

- Verified ([MTLResidencySet](https://developer.apple.com/documentation/metal/mtlresidencyset)): macOS 15 and later, family Apple6 and later. A residency set attaches to a queue once. Apple says it takes "minimal CPU overhead" compared with per-encoder `useResource`. It does no hazard tracking.
- Inference. We don't call `useResource` or use argument buffers, since every buffer goes through `setBuffer`, so residency sets would save little. Skip.

### Indirect command buffers for compute

- Verified. ICB compute support is family Apple3 and up, and ICB memory barriers for compute are also Apple3 and up ([Feature Set Tables](https://developer.apple.com/metal/Metal-Feature-Set-Tables.pdf)). `MTLIndirectComputeCommand` has `setComputePipelineState`, `setKernelBuffer(buffer, offset, index)`, `setThreadgroupMemoryLength`, `concurrentDispatchThreadgroups`, `setBarrier` and `clearBarrier` ([docs](https://developer.apple.com/documentation/metal/mtlindirectcomputecommand); `MTLIndirectCommandEncoder.hpp:87-106`). It has no `setBytes`, so scalar arguments have to live in buffers.
- Inference. An ICB saves host encode time, which isn't our bottleneck, and I know of no evidence that it cuts the GPU cost of a dependent dispatch. Where it helps is GPU-driven control flow: a kernel writes the range buffer or the indirect grid, and the host never waits.
- Concrete use (inference): the multi-kernel CCMA path (`MetalIntegrationUtilities.cpp:95-120`) waits on the host every 4 iterations. Encode blocks of iterations with `dispatchThreadgroups(indirectBuffer, ...)` and have the convergence kernel write zero threadgroups into the remaining blocks. A converged block then costs an empty dispatch of about 2 us instead of a host round trip of 100 to 200 us. benchmark.py doesn't reach this path (lab 022: HBonds dhfr sends nothing to CCMA, and it has 1024 constraints or fewer, which use the single-kernel path at `:87-94`). FAHBench dhfr does reach it (3,072 CCMA constraints).

### Encoding a whole MD step with the fewest submissions

This is my recommended shape, and all of it is inference built on the facts above.

1. One command buffer per step on the default queue, as now, with a concurrent encoder and explicit barriers only on real dependencies.
2. PME reciprocal work in a second command buffer on a second queue, fenced with MTLEvents: an event after positions are ready, and a wait before the force reduction.
3. Keep the neighbor-list count wait (`MetalNonbondedUtilities.cpp:450-451`). CUDA and HIP do the same wait. It is off the critical path whenever the host can encode the rest of the step before the committed force buffer finishes (lab 024: Y takes about 180 us on gbsa). If a profile ever shows the host on the critical path, spin on `signaledValue` for about 50 us before falling back to the blocking wait. Lab 024 measured a 22 us wake with spinning against 100 us blocking.
4. Don't split buffers to get per-kernel timing in production builds. One buffer per dispatch adds about 5 us to every kernel (lab 024).

## 2. Apple9 compute

### Execution model

- Verified. SIMD width is 32 on every Apple GPU ([WWDC22 10159](https://developer.apple.com/videos/play/wwdc2022/10159/); lab 004 simd-alignment probe on both chips).
- Verified. Apple9 limits: 1024 threads per threadgroup and 32 KB of threadgroup memory per threadgroup, allocated in 16-byte steps ([Feature Set Tables](https://developer.apple.com/metal/Metal-Feature-Set-Tables.pdf), limits table).
- Reported, for M1 and M2 (Apple7 and 8, [metal-benchmarks](https://github.com/philipturner/metal-benchmarks)):
  - Per core: about 208 KB of register file, 384 to 3072 threads, about 60 KB of shared memory, an 8 KB L1 data cache and a 12 KB instruction cache.
  - SIMD shuffle bandwidth is 256 B/cycle per core.
  - "ALU utilization maxes out at 24 simds/core."

  These are not Apple9 numbers. The M3 changed the memory system, as described next.
- Reported by Apple, for M3 and A17 Pro ([tech talk 111375](https://developer.apple.com/videos/play/tech-talks/111375/)):
  - Dynamic caching: "On-chip register memory is now dynamically allocated and deallocated over the lifetime of the shader according to what each part of the program actually uses." Register, threadgroup, tile, stack and buffer data "are all cached on chip". Threadgroup memory is now a cache, and it can spill to the next level.
  - An occupancy manager lowers occupancy on its own when the cache thrashes.
  - The Apple9 core "can execute instructions from all three data types [FP32, FP16, integer] in parallel to a greater degree than ever before ... up to 2x ALU performance". This needs instructions "from multiple SIMDgroups", so occupancy still matters.
- Inference. Dynamic caching means the M2 occupancy rules don't carry over. Tune thread blocks per core on the M3 Ultra itself. 24c34d794 tuned "12 thread blocks per core" and "40 force blocks per core" on the M2. `numThreadBlocksPerComputeUnit = 12` still carries a METAL-TODO (`MetalContext.cpp:157-158`). The mixed-precision df64 kernels are integer and FP32 heavy (IEEE load and store conversions, `df64.metal:124-230`), so the Apple9 concurrent int and FP32 issue may hide some of their cost. That's unmeasured.

### SIMD-group operations

- Verified (MSL 4.1 spec 6.10.2). SIMD-group functions take any integer or float scalar or vector except bool, bfloat, long and ulong. Our code already moves 64-bit values as uint2 (`intrinsics.metal:7-13`). Shuffle is Apple6 and up, SIMD reductions Apple7 and up, `simd_shuffle_and_fill` Apple8 and up ([Feature Set Tables](https://developer.apple.com/metal/Metal-Feature-Set-Tables.pdf)).
- Reported costs, M1-era, in cycles of throughput per SIMD ([metal-benchmarks](https://github.com/philipturner/metal-benchmarks)):
  - `simd_ballot`: 2.02
  - `simd_shuffle` and rotate: 2.04
  - `simd_sum<float>`: 14.5
  - `simd_prefix_exclusive_sum<float>`: 11.6
  - quad shuffle: 2.0
  - FFMA32: 1 to 2
  - RSQRT32: 8
  - EXP2 and LOG2: 4
  - 8x8 float simdgroup matmul: about 18

  A `simd_sum` costs about as much as 7 shuffles, so for a full 32-lane tree reduction a hand-written shuffle-xor ladder (5 shuffles and 5 adds) may beat it. Inference, so measure it.
- Verified. The Metal platform already uses shuffles and ballot in the HIP-derived nonbonded and neighbor-list kernels (`nonbonded.metal:277,286`; `findInteractingBlocks.metal:51-61`). This is one thing Metal has that Apple's OpenCL doesn't (section 5).

### simdgroup_matrix

- Verified (MSL 4.1 spec 2.x, "simdgroup_matrix<T,Cols,Rows>"). The types are `simdgroup_half8x8`, `simdgroup_bfloat8x8` (Metal 3.1 and later) and `simdgroup_float8x8`, with `simdgroup_multiply_accumulate` for d = a*b + c. Family Apple7 and up.
- Reported: 101.7 FP32 matrix FFMAs per core per cycle, against 128 scalar ([metal-benchmarks](https://github.com/philipturner/metal-benchmarks)).
- Inference. Nothing in OpenMM's standard force set is a dense 8x8 product. The only candidates I see are a DFT-by-matrix stage for small FFT sizes and the TorchForce or ML plugins. It's low priority.

### Atomics

- Verified (MSL 4.1 spec 6.16.4):
  - `atomic_int` and `atomic_uint` support add, sub, and, or, xor, min and max, with fetch variants.
  - `atomic_float` add and sub work in device memory from Metal 3. "Metal 4.1 and later add atomic_float support for atomic add and sub in threadgroup memory."
  - Metal 4.1 adds memory order, including acquire and release, to barriers and atomics (spec 1.3). The Feature Set Tables list acquire/release atomics for Apple7 and up.
- Verified, and it's the one that matters for forces. The 64-bit atomics (spec 6.16.4.6) are `void atomic_max_explicit` and `void atomic_min_explicit` on `device atomic_ulong*`, with `memory_order_relaxed` only. The Feature Set Tables list "64-bit atomics" from Apple9, with footnote 7: Apple8 has min and max on macOS only, and "the full set of 64-bit atomic operations is supported on all platforms starting with Apple9". The MSL spec defines no 64-bit add, exchange or compare-exchange, so I read "full set" as min and max on buffers and textures on every platform. That's inference, from the two documents together. Lab 004 concluded "64-bit atomics unavailable" after trying `fetch_max`, which isn't the right name. `atomic_max_explicit` probably compiles on the M3 Ultra, but it doesn't help force accumulation.
- Lab 004:
  - The split-word 64-bit add (`common.metal:57-67`) is exact under contention: 2^22 adds into 8 cells took 2.0 ms on the M3 Ultra and 5.1 ms on the M2.
  - Float atomics: 2^20 adds into 8 cells took 0.34 ms on the M3 Ultra and 190.8 ms on the M2. The M2 almost certainly runs a CAS loop and the M3 has a hardware path (inference).
- Lab 011 head note, M3 Ultra, ApoA1 98^3 grid, GPU clock: gridSpreadCharge with float atomics took 0.169 ms, against 0.412 + 0.020 ms for fixed point plus finishSpreadCharge. That's 2.6x. On the M2, float atomics lost: 0.832 against 0.796 ms.
- Verified. `supportsHardwareFloatGlobalAtomicAdd(false)` is hardcoded (`MetalContext.cpp:117`), so `useFixedPointChargeSpreading` is always true on Metal (`MetalKernels.cpp:52`). CUDA spreads with float atomics unless the run is double precision or DeterministicForces (`CudaKernels.cpp:57`). A counterexample exists: HIP went back to fixed point on RDNA4 because `global_atomic_add_f32` was "very slow compared to global_atomic_add_u64" (1ce5d91d9, #4960). So key this on measurement per GPU family, not on the feature bit. Enable it for Apple9 and up (`supportsFamily(MTL::GPUFamilyApple9)`) and keep fixed point on Apple7 and 8.
- Fastest fixed-point accumulation without a 64-bit add (inference, ranked):
  1. Reduce before you touch memory. Sum per-atom contributions in registers and SIMD shuffles, then issue one split-word add per atom per tile. The nonbonded kernel already works this way.
  2. Keep the conditional high-word add. The current code skips it when the carry cancels the sign extension, which is about half the time for mixed signs.
  3. For PME spreading on Apple9, use float atomics, per lab 011.
  4. MSL 4.1 threadgroup float atomics make it possible to privatize a grid tile in threadgroup memory and flush it to device memory with fewer contended atomics. The 32 KB limit is 8K floats, a 20^3 tile, so this only works if atoms are sorted spatially and the tile covers their 5^3 stencil. Speculative.
  5. Don't use CAS loops on 64-bit pairs. Two 32-bit atomics beat a retry loop under contention.

### Fast and precise math

- Verified. The library compiles with `LanguageVersion3_2`, `MathModeSafe` and `MathFloatingPointFunctionsPrecise` (`MetalContext.cpp:483-485`). 24c34d794 maps HIP's `__expf`, `__logf` and `__frsqrt_rn` to MSL `fast::` functions and uses `fast::divide` for RECIP. OpenCL builds with `-cl-mad-enable -cl-no-signed-zeros` (`OpenCLContext.cpp:212`).
- Verified (MSL 4.1 spec 1.6.3):
  - `fast` assumes no NaN, no INF and no signed zeros, and allows reciprocals, reassociation and fast contraction.
  - `relaxed` is the same "but honors INFs and NaNs".
  - `safe` allows no unsafe transformation and sets contraction to "on", meaning within a statement.
  - `#pragma METAL fp math_mode(safe|relaxed|fast)` and `#pragma METAL fp contract(off|on|fast)` apply at file or namespace scope or at the start of a compound statement.
  - Precise fp32 functions promise 1 ulp for exp, log, sin and cos (spec 8.4). Fast ones are much looser: exp is 3 + floor(|2x|) ulp.
- Lab 015: under relaxed or fast math the compiler reassociates TwoSum to zero, and df64 falls back to float precision. `fma` survives every mode.
- Lever (inference). Compile with `MathModeRelaxed`, which honors INF and NaN, and put `#pragma METAL fp math_mode(safe)` at the top of df64.metal, or inside each df64 function body. Then run the forces gate. The expected gain is small, because the hot transcendentals are already fast. The bonded kernels' `acos`, `sin` and `cos` still use the precise versions.

## 3. FFT for PME

- Lab 011 head note, M3 Ultra, 98^3, 32 transforms per sync, wall clock per transform: VkFFT on Metal took 0.067 ms forward and 0.064 ms inverse, the same as VkFFT on OpenCL. MPSGraph was 4 to 7x slower. That's the second MPS loss, so under the MPS rule it's out.
- Verified. The platform uses VkFFT backend 5 (Metal), appended to the shared compute encoder (`MetalFFT3D.cpp:26-106`), with `useLUT = 1`. `findLegalDimension` accepts prime factors up to 13 (`MetalFFT3D.cpp:108-124`).
- Reported ([VkFFT README](https://github.com/DTolm/VkFFT); Tolmachev, [IEEE Access 11:12039, 2023](https://ieeexplore.ieee.org/document/10036080/)):
  - VkFFT has radix 2, 3, 4, 5, 7, 8, 11 and 13 kernels, Rader for primes from 17 up to about 10,000, and Bluestein for everything else.
  - R2C and C2R run "up to 2x faster than C2C".
  - It has native zero padding, and it can fuse a convolution, multiplying by a kernel in frequency space.
- Reported ([arXiv 2603.27569](https://arxiv.org/html/2603.27569), M1, 1D only): a hand-written radix-8 Stockham kernel in MSL reached 138 GFLOPS at N=4096, against vDSP's 107. It keeps the data in registers and uses threadgroup memory only for exchange. The paper says VkFFT's Metal backend caps threadgroups at 256 threads. Its SIMD-shuffle variant was slower, at 61.5 GFLOPS.
- Inference, for PME sizes:
  - OpenMM grids run from about 24^3 to 200^3 and are 3D, R2C, and batched over one axis at a time. VkFFT already does each axis in one pass through threadgroup memory. A 98^3 R2C moves about 3.8 MB each way per axis. Three axes at 0.064 ms work out to roughly 350 GB/s, which is well under the M3 Ultra's roughly 800 GB/s. So a hand-written Stockham has at most about 2x to find, on 0.13 ms per step at ApoA1 size. That's about 4% of apoa1pme, and it isn't worth a lane.
  - The cheaper wins are to fold `reciprocalConvolution` (0.015 ms) into VkFFT's convolution mode, and to limit `findLegalDimension` to 2, 3, 5 and 7, since radix 11 and 13 are the slowest butterflies. Neither is worth more than 1 to 2%.
  - FFT does matter for LJPME, which has two grids, and for the second queue. A small FFT underfills 60 cores, and that's exactly what running it concurrently with nonbonded fixes.

## 4. Emulated fp64 (df64) on Apple GPUs

research/2026-09-23-mixed-without-fp64.md already covers the mixed-precision contract and the options ranked for OpenMM. This section adds only the arithmetic.

- Verified ([Joldes, Muller, Popescu, ACM TOMS 44(2), 2017](https://dl.acm.org/doi/10.1145/3121432), Table 1; u = 2^-24 for float, so u^2 is about 3.6e-15):

| Operation | Algorithm | Relative error bound | FP ops |
|---|---|---|---:|
| DW + FP | Alg. 4 | 2u^2 | 10 |
| DW + DW, sloppy | Alg. 5 | none when signs differ | 11 |
| DW + DW, accurate | Alg. 6 | 3u^2 + 13u^3 | 20 |
| DW x FP, with FMA | Alg. 9 | 2u^2 | 6 |
| DW x DW, with FMA | Alg. 12 | 5u^2 | 9 |
| DW / FP | Alg. 15 | 3u^2 | 10 |
| DW / DW, with FMA | Alg. 18 | 9.8u^2 | 31 |

  The paper says: "never use Algorithm 5, unless you are certain that both operands have the same sign."
- Verified. Our df64 uses FMA two-prod (`df64.metal:12-15`, `df64_two_prod`) and TwoSum (`df64_two_sum`, `:1-5`). It also stores df64 values in device memory as IEEE doubles and converts on every load and store (`df64.metal:102-103` loads through `df64_from_ieee` at `:149`; stores go through `df64_to_ieee` at `:204`). Those conversions run clz, shifts and rounding in 64-bit integer arithmetic.
- Reported ([metal-benchmarks](https://github.com/philipturner/metal-benchmarks)): IADD64 is emulated with 4 instructions, and a 64-bit multiply is 16 cycles. Dynamic bit shifts take 4 cycles. So the IEEE pack and unpack, not the df64 arithmetic, may be where the mixed-precision cost goes (inference). That supports option 4 in the mixed note, storing (hi, lo) pairs for GPU-private arrays.
- Reported ([metal-float64](https://github.com/philipturner/metal-float64)): full IEEE fp64 emulation runs at "1/32-1/64 the throughput" of fp32. The double-single alternative there has 1+47 mantissa bits.
- Cost relative to fp32 (inference, from the flop counts): a df64 add costs about 20x an fp32 add, a multiply about 9x, and a mixed multiply-add about 25 to 30x. Integration kernels are memory bound, so the real ratio is lower, and lab 022 measured the Langevin kernels at 2 to 3x single.
- Hard rule from lab 015: df64 code needs safe math, or the compiler cancels the error terms.

## 5. Apple's OpenCL on Apple silicon, and what it can't use

- Lab 025 (`results/opencl-fp64.txt`): on the M3 Ultra, OpenCL reports version 1.2. Its only cl_khr extensions are gl_event, byte_addressable_store, global and local int32 base and extended atomics, 3d_image_writes, image2d_from_buffer and depth_images, plus some cl_APPLE ones. `cl_khr_fp64` is absent and DOUBLE_FP_CONFIG is 0, so OpenMM refuses mixed and double there.
- Absent from that list: `cl_khr_subgroups`, `cl_khr_int64_base_atomics`, `cl_khr_fp16`, and every float-atomic extension. OpenMM's OpenCL kernels therefore use threadgroup memory where Metal can shuffle, CAS loops or fixed point where Metal has hardware float atomics, and no fp16.
- Reported ([opencl-metal-stdlib](https://github.com/philipturner/opencl-metal-stdlib)): Apple's M1 OpenCL compiler lowers to AIR, the same IR Metal uses, and `__asm` can bind AIR symbols. The SIMD-scoped operations exist in hardware, but "Apple does not expose such operations to the shading language" in OpenCL. Lab 004 found that `CL_PROGRAM_BINARIES` returns a plist of source and options, not machine code, so the backend is shared and invisible.
- Lab 008: OpenCL's profiling timestamps are raw mach ticks, 125/3 ns each, not nanoseconds. Its per-dispatch host cost is 0.385 us, against Metal's 0.112. Pipelined step throughput was equal.
- What this means (inference): Metal's advantages over OpenCL are, in order, float atomics on Apple9, concurrency (multiple queues and concurrent dispatch), SIMD-group operations, MSL 4.1 threadgroup float atomics and acquire/release, and cheap host syncs. The kernels themselves run at the same speed when the code is the same.

## 6. Timing and profiling

- Verified ([gpuStartTime](https://developer.apple.com/documentation/metal/mtlcommandbuffer/gpustarttime)): `GPUStartTime` and `GPUEndTime` are host time in seconds, "relative to system mach time", and valid only after completion. So they share one clock with `mach_absolute_time` on the host, as labs 022 and 024 used them. Each covers a whole command buffer.
- Counter sample buffers (classic):
  - Reported ([tech talk 10001](https://developer.apple.com/videos/play/tech-talks/10001/)): Apple silicon supports only stage-boundary sampling, meaning the start and end of a compute pass, with no dispatch boundary.
  - Reported ([wgpu #9414](https://github.com/gfx-rs/wgpu/issues/9414), macOS 26.3.1, M3 Pro): `MTLCounterSampleBuffer` timestamps come back all zero, `supportsCounterSampling` is false for the draw, dispatch and blit boundaries, and Apple's replacement is `MTL4CounterHeap`.
  - Someone should probe this on macOS 27.2 before relying on it. Metal-cpp has `supportsCounterSampling(CounterSamplingPoint)` (`MTLDevice.hpp:554`).
- Metal 4 timestamps:
  - Verified ([writeTimestamp](https://developer.apple.com/documentation/metal/mtl4computecommandencoder/writetimestamp(granularity:counterheap:index:)); `MTL4ComputeCommandEncoder.hpp:120`; `MTL4Counters.hpp:34-46`). `writeTimestamp(granularity, counterHeap, index)` "ensures that any prior work finishes, but doesn't delay any subsequent work". `precise` requests "the most detail" at some runtime cost, and `relaxed` "may group all timestamps for a pass together".
  - The heap comes from `device->newCounterHeap(desc)` with `CounterHeapTypeTimestamp`. Read it with `resolveCounterRange`, or on the GPU with `MTL4CommandBuffer::resolveCounterHeap`.
  - The tick rate is `device->queryTimestampFrequency()`, and `sampleTimestamps(cpu, gpu)` correlates the GPU and host clocks (`MTLDevice.hpp:522,536`).
  - Performance counter heaps are Apple7 and up (Feature Set Tables). This is the only in-process way to get per-dispatch GPU times without splitting command buffers, which adds about 5 us per kernel (lab 024). It needs an MTL4 submission path for the profiled run.
- MTL4 commit feedback: `MTL4CommitFeedback` returns `GPUStartTime` and `GPUEndTime` per commit (`MTL4CommitFeedback.hpp:41-51`).
- Metal System Trace from the command line, once Xcode is installed. xctrace comes with Xcode, not the Command Line Tools, which is why lab 024 couldn't use it. The options below are verified from the [xctrace man page](https://keith.github.io/xcode-man-pages/xctrace.1.html):
  - `xcrun xctrace list templates` should list "Metal System Trace".
  - `xcrun xctrace record --template 'Metal System Trace' --time-limit 20s --output /tmp/openmm-metal-bench/ultra-<lane>/run.trace --launch -- /path/to/python benchmark.py ...`. `--attach <pid>` and `--all-processes` also exist, and `--env VAR=value` passes environment variables.
  - `xcrun xctrace export --input run.trace --toc` gives the table of contents, then `--xpath '<expr>'` pulls a table as XML, so the results can be read over SSH without Instruments.
  - Unverified: whether recording GPU tracks over a non-GUI SSH session needs extra privileges or `DevToolsSecurity`. Test a 5 s record first.
- Discipline reminders from the lab: name the clock in every table (011 head note). Apple's OpenCL ticks need x125/3 (008). A kernel the compiler can prove side-effect free gets deleted (008 head note).

## Ranked levers for the lanes

| # | Lever | Lane | Tier of the evidence | Expected gain |
|---|---|---|---|---|
| 1 | Float-atomic PME spreading on Apple9 and up; fixed point on 7 and 8, and for DeterministicForces | PME | lab 011 (2.6x on the kernel), verified code path | 10-15% apoa1pme, more on ljpme, less on pme (inference) |
| 2 | PME on a second MTLCommandQueue, MetalDisablePmeStream default false | PME, dispatch | verified plumbing, Apple guidance | 5-20% on PME tests (inference) |
| 3 | Concurrent encoder, no barriers between force-accumulation kernels | dispatch, nonbonded | Apple guidance, lab 008 barrier cost | 5-15% small systems (inference) |
| 4 | Fewer dependent dispatches: fold clears and reductions into producers, using MSL 4.1 acquire/release for "last threadgroup reduces" | dispatch, mixed | lab 024 counts, spec | up to 10% gbsa and rf (inference) |
| 5 | Retune thread blocks per core and force blocks on the M3 Ultra, not the M2 | nonbonded | 24c34d794 tuned on M2; dynamic caching | 0-5% (inference) |
| 6 | MathModeRelaxed with df64 fenced by a safe-math pragma | all | spec, lab 015 | 0-5% (inference) |
| 7 | df64 stored as (hi, lo) pairs in GPU-private arrays, avoiding IEEE pack and unpack | mixed | verified code, reported int64 costs | 1-3% mixed per the mixed note, maybe more (inference) |
| 8 | GPU-driven CCMA early exit through indirect dispatch | mixed (FAH) | verified APIs | FAHBench dhfr only; 0 on benchmark.py |
| 9 | MTL4CounterHeap per-dispatch timing in a profiler build; xctrace | all | verified headers and docs | measurement only |
| 10 | VkFFT convolution fusion, and limiting FFT radices to 7 and below | PME | reported | 1-2% (inference) |

Dead ends I'd skip:

- A Metal 4 port for speed (lab 008).
- MPSGraph FFT (lab 011).
- Gather-based spreading (lab 011).
- 64-bit atomic add, which doesn't exist (MSL 4.1 spec 6.16.4.6).
- Sloppy df64 add (Joldes et al.).
- Residency sets, since we bind with setBuffer.
- ICBs for host-cost reasons.

## Conflicts and open questions

- The Feature Set Tables say Apple9 has "the full set of 64-bit atomic operations", while MSL 4.1 defines only max and min for atomic_ulong. I trust the spec for what compiles. A probe of `atomic_max_explicit((device atomic_ulong*)p, v, memory_order_relaxed)` on the M3 Ultra would settle it in 5 minutes.
- Lab 008's overview says the M3 Ultra has "32 CPU cores, 80 GPU cores". RULES.md and the IORegistry-based code say 28 and 60. 008's M3 Ultra rows came from some machine, so anyone quoting them should check which one.
- metal-benchmarks' microarchitecture numbers are M1 and M2. Apple9's dynamic caching and concurrent FP32, FP16 and int issue change occupancy and the instruction mix, so treat them as a floor.
- Classic counter sample buffers returning zeros on macOS 26 is one bug report. It's unverified on 27.2.
- Whether `memoryBarrier(resources:)` in a concurrent encoder is scoped to those resources or is a full barrier is unverified. Probe it before designing two interleaved chains in one encoder.
- HIP found float atomics slower than 64-bit integer atomics on RDNA4 (#4960). On Apple9 our lab measured the opposite. Re-measure inside the real benchmark before shipping.

## Pointers

- [Metal Shading Language spec 4.1](https://developer.apple.com/metal/Metal-Shading-Language-Specification.pdf), sections 1.6.3 (math modes and pragmas), 6.10.2 (SIMD-group functions), 6.16.4 (atomics, including 64-bit) and 8.4 (ulp tables). This is the ground truth for what compiles.
- [Metal Feature Set Tables](https://developer.apple.com/metal/Metal-Feature-Set-Tables.pdf), dated May 21, 2026: family support for Metal 4, float atomics, 64-bit atomics, ICB barriers and counter heaps, plus the per-family limits.
- [WWDC22 10159, Scale compute workloads across Apple GPUs](https://developer.apple.com/videos/play/wwdc2022/10159/): Apple's own guidance on concurrent dispatch, second queues, shared events and Ultra scaling. It's the closest thing to a playbook for the dispatch lane.
- `libraries/metal-cpp/Metal/MTL4ComputeCommandEncoder.hpp`, `MTL4Counters.hpp`, `MTLComputeCommandEncoder.hpp` and `MTLIndirectCommandEncoder.hpp` in the base worktree: the exact C++ surface available to us.
- Lab experiments 008 (submission costs), 011 plus its HEAD-NOTE (PME and FFT, like-for-like), 024 (gbsa step anatomy) and 004 (atomics probes): our own numbers, which beat any external benchmark for this machine.

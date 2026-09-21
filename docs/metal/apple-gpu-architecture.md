# Apple GPU architecture for compute kernels

This document outlines the hardware characteristics of Apple Silicon GPUs (M1 through M5) relevant to scientific compute and molecular dynamics kernel design. Sources include empirical measurements from `philipturner/metal-benchmarks` (commit `dc2adc640a1588246f4471d415aa6873cb6e3499`), Asahi Linux driver documentation, Alyssa Rosenzweig's and Asahi Lina's published write-ups on the AGX hardware, Apple Metal Feature Set Tables, and Apple WWDC technical sessions.

## Core organization and ALU execution resources

### Core structure and execution units
Each Apple GPU core contains 4 SIMD units. Each SIMD unit executes 32 threads in lockstep.
- FP32 ALUs per core: 4 SIMD units * 32 lanes = 128 FP32 ALUs per core.
- FP32 instruction throughput: 1 FMA per cycle per ALU = 256 FP32 FLOP per cycle per core.
- FP16 instruction throughput: 2 FMA per cycle per ALU = 512 FP16 FLOP per cycle per core (2x rate of FP32).
- FP64 instruction throughput: 0 ALUs. The hardware contains no 64-bit floating-point execution units.

### Core counts, clock speeds, and theoretical FP32 performance
Theoretical FP32 throughput equals `core_count * 128 ALUs * 2 operations * clock_frequency`:

| Chip | Architecture family | GPU cores | Clock frequency (MHz) | Peak FP32 (TFLOPS) | Memory bandwidth (GB/s) |
| --- | --- | --- | --- | --- | --- |
| M1 Base | Apple 7 (G13) | 7 or 8 | 1278 | 2.29 - 2.62 | 68.3 (LPDDR4X) |
| M1 Pro | Apple 7 (G13) | 14 or 16 | 1296 | 4.63 - 5.29 | 200 (LPDDR5) |
| M1 Max | Apple 7 (G13) | 24 or 32 | 1296 | 7.94 - 10.59 | 400 (LPDDR5) |
| M1 Ultra | Apple 7 (G13) | 48 or 64 | 1296 | 15.88 - 21.18 | 800 (LPDDR5) |
| **M2 Base (Lab Machine)** | **Apple 8 (G14)** | **8 or 10** | **1398** | **2.86 - 3.58** | **100 (LPDDR5)** |
| M2 Pro | Apple 8 (G14) | 16 or 19 | 1398 | 5.73 - 6.80 | 200 (LPDDR5) |
| M2 Max | Apple 8 (G14) | 30 or 38 | 1398 | 10.74 - 13.60 | 400 (LPDDR5) |
| M2 Ultra | Apple 8 (G14) | 60 or 76 | 1398 | 21.47 - 27.21 | 800 (LPDDR5) |
| M3 Base | Apple 9 (G15) | 8 or 10 | 1380 | 2.83 - 3.53 | 100 (LPDDR5) |
| M3 Pro | Apple 9 (G15) | 14 or 18 | 1380 | 4.94 - 6.36 | 150 (LPDDR5, 192-bit) |
| M3 Max | Apple 9 (G15) | 30, 36, or 40 | 1380 | 10.60 - 14.13 | 300 or 400 (LPDDR5) |
| M4 Base | Apple 10 (G16) | 8 or 10 | 1660 | 3.40 - 4.26 | 120 (LPDDR5X) |
| M4 Pro | Apple 10 (G16) | 16 or 20 | 1660 | 6.80 - 8.50 | 273 (LPDDR5X) |
| M4 Max | Apple 10 (G16) | 32 or 40 | 1660 | 13.60 - 17.00 | 410 or 546 (LPDDR5X) |
| M5 Base | Apple 11 / Metal 4 | 10 | ~1850 | ~4.74 | ~150 (LPDDR5X) |

*Sources: Apple Developer Specifications, Philip Turner `metal-benchmarks/README.md` (lines 124-155), Asahi Linux device tree database.*

### Measured compute efficiency
Theoretical peak numbers assume independent FMA operations every cycle. On real workloads, instruction dependencies restrict sustained throughput:
- In dense GEMM matrices utilizing `simdgroup_matrix`, sustained throughput reaches 80% to 92% of theoretical peak (`metal-benchmarks/CommandConcurrency/MainFile.swift`, lines 80-97).
- In pairwise potential equations (such as Lennard-Jones in `moleqular/README.md`, lines 33-43), serial dependencies (distance squared -> reciprocal square root -> powers 6 and 12 -> force scale) create a 10-cycle dependency chain. On an M4 GPU with 4.26 TFLOPS theoretical peak, all-pairs Lennard-Jones sustains 810 GFLOPS (19% of theoretical peak).

## Execution width and SIMD-group behavior

### Hardware SIMD width
Across all Apple Silicon generations (A14 through A18, M1 through M5), the native hardware execution width is 32 threads:
- Metal pipeline state query `[pipelineState threadExecutionWidth]` returns 32.
- In Metal Shading Language (MSL), `[[threads_per_simdgroup]]` is 32.
- Built-in SIMD collectives (`simd_sum`, `simd_prefix_inclusive_sum`, `simd_shuffle`) operate across exactly 32 threads.

### Comparison to other architectures
- NVIDIA CUDA: 32 threads (warp).
- AMD RDNA / GCN: 32 or 64 threads (wavefront).
- Intel Integrated: 16 or 32 threads.
OpenMM's legacy OpenCL platform on macOS suffered from a major bug documented by Philip Turner (`openmm-metal/README.md` and OpenMM issue #5397): Apple's deprecated OpenCL driver frequently reported a preferred workgroup size of 1 or 64, misaligning dispatch dimensions and degrading performance by up to 4x until patched.

### SIMD divergence penalties
Apple GPU cores lack independent per-thread program counters within a SIMD group. When threads within a SIMD group branch along different execution paths:
1. The hardware executes each branch serially, masking off inactive lanes.
2. In the worst case (such as traversing divergent neighbor lists or scattered cell grids), execution time equals the sum of all branch paths taken by any thread in the SIMD group.
3. In `moleqular/README.md` (lines 178-183), cell-list neighbor searches on M4 dropped per-pair utilization from 19% to 3% because threads in the same SIMD group accessed different neighbor cells. Grouping atoms into 8x8 or 32-atom tiles restored SIMD convergence.

## Threadgroup memory and the M3 dynamic caching transition

### Pre-M3 architecture (Apple 7 and Apple 8: M1, M2)
On M1 and M2 GPUs, each core contains dedicated, physically isolated on-chip SRAM allocated for threadgroup memory:
- Physical threadgroup SRAM per core: approximately 60 KiB (`metal-benchmarks/README.md`, line 86).
- Physical register file per core: approximately 208 KiB (`metal-benchmarks/README.md`, line 85; Alyssa Rosenzweig, "Dissecting the Apple M1 GPU").
- Allocation mechanism: Compile-time static reservation. When a kernel requests threadgroup memory (for example, 16 KiB per threadgroup), the hardware statically reserves that allocation for each resident threadgroup from the core's 60 KiB budget.
- Occupancy cliff: A threadgroup requiring 32 KiB of threadgroup memory prevents more than 1 threadgroup from occupying the core simultaneously, even if registers and ALUs are idle.

### Post-M3 architecture (Apple 9 and later: M3, M4, M5)
With the M3 generation (Apple 9 family), Apple introduced **Dynamic Caching**:
- Physical restructuring: The rigid physical partitioning between register storage, threadgroup memory, and local data cache was replaced with a dynamic, unified on-chip cache pool.
- Allocation mechanism: Local memory is allocated dynamically in real time as threads execute, rather than statically pre-allocating the maximum declared memory for every scheduled threadgroup.
- Evidence from Philip Turner: In OpenMM issue #5397 (comment 4), Turner noted: "M3 and later have a different architecture where `__local` memory is scoped in a different way, perhaps that changes latencies or some dynamic where SIMD-scoped reductions are omitted." In his M4 microbenchmark gists (`gist.github.com/philipturner/40052a700a448b9356b998154cd7e4cd`), dynamic caching prevents occupancy collapse when threadgroup memory or temporary register usage fluctuates during execution.
- Compute impact: For molecular dynamics kernels, Dynamic Caching allows kernels with moderate threadgroup memory requirements (such as 4 to 16 KiB for tile staging) to maintain high occupancy alongside register-heavy force evaluations.

## Unified memory hierarchy and memory bandwidth

Apple Silicon places the CPU, GPU, and Neural Engine on a unified memory bus accessing shared LPDDR5/LPDDR5X DRAM packages.

### Memory bandwidth breakdown
The dedicated test machine for this laboratory is the base M2 Mac mini:
- Bus width: 128-bit (dual 64-bit channels).
- DRAM technology: LPDDR5-6400 (3200 MHz clock, double data rate).
- Theoretical peak bandwidth: `128 bits * 6400 MT/s / 8 bits/byte = 102.4 GB/s` (commonly cited as 100 GB/s).
- Measured sustained bandwidth: 80 to 85 GB/s under contiguous streaming reads.

Bandwidth across other base configurations:
- Base M1: 68.3 GB/s (128-bit LPDDR4X-4266).
- Base M2: 100 GB/s (128-bit LPDDR5-6400).
- Base M3: 100 GB/s (128-bit LPDDR5-6400).
- Base M4: 120 GB/s (128-bit LPDDR5X-7500).
- Base M5: ~150 GB/s (estimated LPDDR5X).

### On-chip cache hierarchy (M1 and M2)
From `metal-benchmarks/README.md` (lines 80-106) and Asahi Linux documentation:
- Register file: ~208 KiB per core. Register file bandwidth is 256 bytes per cycle per core.
- L1 data cache: 8 KiB per core on Apple 7/8, expanded to 32 KiB on Apple 9+. On-core data bandwidth is 64 bytes per cycle.
- System Level Cache (SLC): 8 MB on base M1/M2, 16 MB on M4, 24-48 MB on Pro/Max, 96 MB on Ultra. SLC bandwidth is 15.4 to 19.8 bytes per cycle per core.
- DRAM: Accessible at 7.7 to 9.9 bytes per cycle per core on base chips.

## Memory management, wired limits, and page faults

### Working set size on an 8 GB machine
On macOS, `device->recommendedMaxWorkingSetSize()` returns the maximum allocation the system permits a GPU process to hold without risking out-of-memory termination:
- On an 8 GB machine (the lab Mac mini), `recommendedMaxWorkingSetSize` reports approximately 5.33 GB to 5.72 GB (66% to 71% of physical memory).
- macOS reserves the remaining ~2.5 GB for operating system processes, kernel wired memory, and window server display buffers.
- MLX enforces an internal garbage collection limit at 95% of `recommendedMaxWorkingSetSize` (`mlx/backend/metal/allocator.cpp`, line 64): on an 8 GB machine, this threshold is approximately 5.06 GB.

### Page residency and wired memory
In macOS unified memory, allocating a buffer with `MTL::ResourceStorageModeShared` reserves virtual address space, but pages are mapped on demand.
- If pages are unmapped or compressed by the OS compressor under memory pressure, the first GPU access triggers a page fault.
- GPU page faults are resolved by the Unified Address Translator (UAT) in coordination with the macOS Mach kernel, introducing latency spikes ranging from 50 microseconds to several milliseconds.
- Pinning memory via `MTL::ResidencySet` (introduced in Metal 3, macOS 14+) instructs the OS kernel to keep the underlying physical pages wired, eliminating GPU page faults during simulation steps.
- MLX bounds residency sets to 5% of `recommendedMaxWorkingSetSize` per set and caps the queue to 32 residency sets (`mlx/backend/metal/resident.h`, lines 25-80).

## Dispatch overhead, round-trip latency, and firmware scheduling

### Firmware-scheduled execution (ASC and RTKit)
As documented by Asahi Linux and Asahi Lina ("SW:AGX driver notes"):
1. The host CPU does not program GPU execution pipelines directly.
2. An embedded ARM64 management coprocessor (the ASC - Apple Storage/System Controller) runs Apple's proprietary real-time firmware (RTKit).
3. The host Metal driver writes command descriptors into shared-memory channel ring buffers and signals a hardware mailbox doorbell.
4. The RTKit firmware processes the command descriptors, executes command sequences ("micro-sequences"), monitors thermal and power limits (DVFS), context-switches hardware queues, and dispatches work to the GPU shader cores.

### Measured latency characteristics
- CPU command encoding cost: 2 to 5 microseconds per compute command encoder.
- Command buffer round-trip latency: 10 to 25 microseconds. This represents the time from calling `[commandBuffer commit]` on the CPU until a completion handler or `[commandBuffer waitUntilCompleted]` returns.
- Firmware queue constraints: Each firmware queue job accepts a maximum of 64 commands (Asahi Linux AGX documentation). Submitting more commands forces segmentation into multiple firmware operations.
- Latency penalty of single-dispatch command buffers:
  If an OpenMM simulation step invokes 40 separate kernels (bonded, nonbonded, constraints, integration) and commits each kernel in its own command buffer (as done in NORPG's current `MetalKernel::execute`), the host CPU incurs `40 * 15 µs = 600 µs` (0.6 ms) of pure scheduling and round-trip overhead per step.
  Batching all 40 dispatches into a single command buffer amortizes the round-trip overhead to ~15 µs total for the entire time step.

## Precision and arithmetic support

### Floating-point arithmetic
- FP32: Fully native. 128 ALUs per core, 1 FMA/cycle/ALU = 256 FLOP/cycle/core.
- FP16: Fully native. 256 ALUs per core, 1 FMA/cycle/ALU = 512 FLOP/cycle/core.
- BFloat16: Native conversions and matrix operations supported from M2 (Apple 8) onward.
- FP64 (double precision): **No native hardware support.**
  Apple GPUs contain zero 64-bit floating-point units.
  In `metal-benchmarks/README.md` (lines 128, 137), Philip Turner measured emulated FP59 (e11m48) operations:
  * FP64 addition: 1:36 throughput ratio compared to FP32.
  * FP64 multiplication: 1:52 throughput ratio compared to FP32.
  * FP64 FMA: 1:68 throughput ratio compared to FP32.
  Running full double-precision force calculations in software emulation reduces compute performance by ~50x.

### Integer arithmetic
- Int32 / UInt32: Native. 128 adds and 32 multiplications per cycle per core (`metal-benchmarks/README.md`, lines 143-144).
- Int64 / UInt64: Emulated by pairing 32-bit integer ALUs.
  * 64-bit addition: 32 operations per cycle per core (1/4 the throughput of 32-bit addition).
  * 64-bit multiplication: 8 operations per cycle per core (1/4 the throughput of 32-bit multiplication).

### Atomic operations
- 32-bit integer atomics: Native hardware support for add, sub, min, max, and compare-and-swap (CAS) on all generations.
- 32-bit floating-point atomics:
  * M1 and M2 (Apple 7 and Apple 8): **No hardware floating-point atomics.** FP32 atomic addition requires an emulated compare-and-swap loop using `atomic_compare_exchange_weak_explicit`.
  * M3, M4, and M5 (Apple 9 and later): Native hardware support for 32-bit floating-point atomic addition (`atomic_fetch_add_explicit<float>`).
- 64-bit integer atomics:
  * M1 and M2 (Apple 7 and Apple 8): No 64-bit atomics.
  * M3, M4, and M5 (Apple 9 and later): Hardware supports 64-bit integer atomic `min` and `max` only. As verified by NORPG and Codex in OpenMM issue #5397 (comment 16), **64-bit integer atomic add is not implemented on the GPU**, despite being referenced in compiler intermediate representations.

## Hardware feature comparison table

| Architectural feature | Apple 8 (M2) | Apple 9 (M3) | Apple 10 (M4) | Apple 11 / Metal 4 (M5) | Source |
| --- | --- | --- | --- | --- | --- |
| Base GPU core count | 8 or 10 | 8 or 10 | 8 or 10 | 10 | Apple tech specs |
| Max GPU core count (Ultra) | 76 | 40 (Max; no Ultra released) | 40 (Max) | TBD | Apple tech specs |
| Base GPU clock frequency | 1398 MHz | 1380 MHz | 1660 MHz | ~1850 MHz | Asahi Linux device tree / `moleqular` |
| Peak FP32 FLOPS (Base 10-core) | 3.58 TFLOPS | 3.53 TFLOPS | 4.26 TFLOPS | ~4.74 TFLOPS | Calculated: `cores * 256 * clock` |
| Base memory bus width | 128-bit | 128-bit | 128-bit | 128-bit | Apple tech specs |
| Base memory bandwidth | 100 GB/s (LPDDR5) | 100 GB/s (LPDDR5) | 120 GB/s (LPDDR5X) | ~150 GB/s (LPDDR5X) | Apple tech specs |
| Hardware SIMD width | 32 | 32 | 32 | 32 | Metal API (`threadExecutionWidth`) |
| Register file per core | ~208 KiB | ~208 KiB | ~208 KiB | ~208 KiB | `metal-benchmarks`, Rosenzweig |
| Threadgroup memory architecture | Static dedicated SRAM (~60 KiB/core) | Dynamic Caching (shared on-chip cache) | Dynamic Caching (shared on-chip cache) | Dynamic Caching (shared on-chip cache) | Apple WWDC23; Turner issue #5397 |
| Native FP32 atomic add | No (CAS loop required) | Yes | Yes | Yes | Metal Shading Language Spec 3.1 |
| 64-bit integer atomic add | No | No | No | No | NORPG/openmm issue #5397, MSL Spec |
| 64-bit integer atomic min/max | No | Yes | Yes | Yes | MSL Spec 3.1; issue #5397 |
| Hardware FP64 support | None (0 ALUs) | None (0 ALUs) | None (0 ALUs) | None (0 ALUs) | `metal-benchmarks/README.md` |
| Int64 addition throughput | 32 ops/cycle/core (1/4 I32) | 32 ops/cycle/core (1/4 I32) | 32 ops/cycle/core (1/4 I32) | 32 ops/cycle/core (1/4 I32) | `metal-benchmarks/README.md` |
| In-shader neural acceleration | None | None | None | NAX (macOS 26.2+) | `mlx/backend/metal/device.cpp` |
| Recommended working set (8 GB) | ~5.33 GB | ~5.33 GB | ~5.33 GB | ~5.33 GB | Metal API query on 8 GB Mac |

## Consequences for an OpenMM Metal platform

1. **Avoid FP64 force pipelines**: Because Apple Silicon has 0 double-precision ALUs and emulates FP64 at 1:36 to 1:68 throughput, OpenMM's `Double` precision platform mode must not be used on Metal. Simulations must use `Single` precision or `Mixed` precision (single-precision force evaluations with 64-bit fixed-point force accumulation in integer buffers).
2. **Handle the 64-bit atomic add limitation**: In OpenMM's CUDA and OpenCL platforms, mixed-precision force accumulation relies on 64-bit integer atomic add (`atomicAdd` on `long long`). Because Apple GPUs do not support 64-bit atomic add, OpenMM Metal must either:
   - Accumulate forces into separate per-threadgroup or per-SIMD force buffers and run a final reduction pass.
   - Use 32-bit floating-point atomic additions on M3 and newer chips (`atomic_fetch_add_explicit<float>`).
   - Use CAS loops over 64-bit values (`atomic_compare_exchange_weak_explicit`), which incurs contention overhead.
3. **Exploit native FP32 atomics on M3+ for PME charge spreading**: Peter Eastman identified `gridSpreadCharge` (14% of apoa1pme wall time) as a primary Metal optimization target. On M3 and newer GPUs, charge spreading can write directly to the 3D grid using hardware FP32 atomic adds. On M2 (the lab machine), a fallback using CAS loops or slice-based threadgroup accumulation is required.
4. **Target 32-thread SIMD boundaries**: All threadgroup allocations and reduction loops must align with 32-thread SIMD execution width (`thread_execution_width = 32`). Algorithms that assumed 64-wide wavefronts (from AMD OpenCL) or arbitrary workgroup sizes will incur branch divergence and inactive lane penalties.
5. **Batch kernel dispatches to hide firmware scheduling latency**: Each command buffer round trip through the RTKit firmware coprocessor takes 10 to 25 microseconds. OpenMM must encode all forces, PME operations, and integration steps for a time step into one or two command buffers, eliminating per-kernel submission stalls.
6. **Account for the 5.3 GB memory boundary on 8 GB machines**: On the lab Mac mini, total GPU allocations across particles, grids, neighbor lists, and scratch buffers must remain below 5.3 GB. Pre-allocating and pinning these buffers via `MTL::ResidencySet` prevents operating system paging and page fault latency spikes during benchmark execution.

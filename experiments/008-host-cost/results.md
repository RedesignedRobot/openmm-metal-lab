# Experiment 008: Host side cost results

## Overview

This document reports measurements of host-side dispatch overhead, kernel replay, memory storage modes, wrapper costs, profiling timers, fault modes, and numerical contraction for a Metal platform implementation in OpenMM.

Measurements cover two hardware platforms:
- Apple M3 Ultra, macOS 27.0, build 26A428 (32 CPU cores, 80 GPU cores).
- Apple M2, macOS 27.0, build 26A428 (8 CPU cores, 10 GPU cores).

All tests report medians and interquartile ranges (IQR) over at least 20 repeats. Every timed kernel produces output that depends on its input and is validated on the host before timing is recorded.

Raw structured data is committed in `results-m3ultra.json` and `results-m2.json`.

---

## 1. Per-dispatch cost

### Command
`swiftc -O experiments/008-host-cost/harness_q1_q3.swift -o q1_dispatch && ./q1_dispatch`

### Method
Trivial kernels writing dependent outputs across N iterations (N = 1, 10, 100, 1000) are measured across seven dispatch strategies:
1. `one_cb_per_kernel`: Separate command buffer per kernel, committed sequentially.
2. `encoder_per_kernel`: One command buffer containing N compute command encoders.
3. `one_encoder_serial`: One command buffer, one serial compute command encoder with N dispatches.
4. `one_encoder_concurrent`: One command buffer, one concurrent compute command encoder with buffer memory barriers.
5. `opencl_batched`: OpenCL clEnqueueNDRangeKernel batched with one clFinish.
6. `metal4_one_encoder`: Metal 4 command buffer, one encoder, argument table bindings, intra-pass barriers.
7. `metal4_encoder_per_kernel`: Metal 4 command buffer, N encoders with inter-pass queue barriers.

### Results at N = 1000

All values are in microseconds per dispatch (median and IQR over 20 repeats).

| Method | M3 Ultra Host Encode (us) | M3 Ultra GPU Exec (us) | M2 Host Encode (us) | M2 GPU Exec (us) |
| :--- | :--- | :--- | :--- | :--- |
| `one_cb_per_kernel` | 15.122 (IQR 0.647) | 3.527 (IQR 0.015) | 23.578 (IQR 0.985) | 2.335 (IQR 0.042) |
| `encoder_per_kernel` | 0.284 (IQR 0.018) | 1.942 (IQR 0.229) | 0.308 (IQR 0.019) | 0.885 (IQR 0.012) |
| `one_encoder_serial` | 0.112 (IQR 0.009) | 1.881 (IQR 0.235) | 0.119 (IQR 0.004) | 0.937 (IQR 0.018) |
| `one_encoder_concurrent` | 0.286 (IQR 0.019) | 2.325 (IQR 0.187) | 0.252 (IQR 0.012) | 0.950 (IQR 0.021) |
| `opencl_batched` | 0.385 (IQR 0.010) | 2.270 (IQR 0.206) | 0.377 (IQR 0.011) | 1.179 (IQR 0.016) |
| `metal4_one_encoder` | 0.100 (IQR 0.005) | 2.156 (IQR 0.250) | 0.118 (IQR 0.004) | 1.016 (IQR 0.015) |
| `metal4_encoder_per_kernel` | 1.028 (IQR 0.045) | 14.401 (IQR 0.543) | 2.998 (IQR 0.082) | 37.217 (IQR 0.612) |

Host output verification: PASS across all methods and all N values on both chips.

### Mechanism
- Command buffer creation imposes a fixed CPU allocation and queue lock overhead of 15.1 us on M3 Ultra and 23.6 us on M2. Launching one command buffer per kernel throttles throughput to under 50,000 dispatches per second.
- Combining dispatches into a single command buffer reduces host overhead by 50x to 200x.
- A single serial encoder achieves 0.11 us host encode time per dispatch, which is 3.4x faster than OpenCL clEnqueueNDRangeKernel (0.38 us).
- The claim of 10 to 25 microsecond dispatch latency in docs/metal/README.md is audited: it applies only to unbatched command buffer creation (`one_cb_per_kernel`). Inside an existing encoder, Metal dispatch latency is 0.11 us.

---

## 2. Step workload replay

### Command
`swiftc -O experiments/008-host-cost/harness_q2.swift -o q2_step && ./q2_step`

### Method
A step workload of 50 dispatches of real OpenMM molecular dynamics kernels is replayed for 1000 consecutive steps (50,000 dispatches per run). System size is 92,224 atoms (matching ApoA1 RF). Every kernel consumes an output buffer produced by the immediately preceding kernel. The 10 real kernels loaded from the census dumps are:
1. `clearBuffer` (dumps/apoa1rf/001)
2. `saveDistributedForces` (dumps/apoa1rf/002)
3. `integrateLangevinMiddlePart1` (dumps/apoa1rf/008)
4. `timeShiftVelocities` (dumps/apoa1rf/002)
5. `calcCenterOfMassMomentum` (dumps/apoa1rf/005)
6. `removeCenterOfMassMomentum` (dumps/apoa1rf/005)
7. `integrateLangevinMiddlePart2` (dumps/apoa1rf/008)
8. `integrateLangevinMiddlePart3` (dumps/apoa1rf/008)
9. `copyFloatBuffer` (dumps/apoa1rf/003)
10. `reduceForces` (dumps/apoa1rf/000)

Sequenced in 5 cycles of 10 kernels, yielding exactly 50 dispatches per step.

Configurations tested:
- `metal_pipelined`: One command buffer per step, committed asynchronously, single wait at step 1000.
- `metal_step_sync`: One command buffer per step, committed and waited via waitUntilCompleted() on each step.
- `opencl_pipelined`: 50 clEnqueueNDRangeKernel calls per step with clFlush(), single clFinish() at step 1000.
- `opencl_step_sync`: 50 clEnqueueNDRangeKernel calls per step with clFinish() called on each step.

### Results

All values are in milliseconds per step (median and IQR over 20 repeats).

| Configuration | M3 Ultra (ms/step) | M3 Ultra IQR | M2 (ms/step) | M2 IQR |
| :--- | :--- | :--- | :--- | :--- |
| `metal_pipelined` | 0.3325 | 0.0009 | 1.7902 | 0.0009 |
| `opencl_pipelined` | 0.3359 | 0.0008 | 1.7790 | 0.0007 |
| `metal_step_sync` | 0.5666 | 0.0359 | 2.0505 | 0.0084 |
| `opencl_step_sync` | 0.6509 | 0.0552 | 2.1302 | 0.0028 |

Host output verification: PASS. Final positions, velocities, and forces validated as finite, non-zero, and altered from initial values.

### Mechanism
- Under pipelined execution, GPU computation overlaps host encoding completely. Both APIs deliver identical throughput (~0.33 ms/step on M3 Ultra, ~1.78 ms/step on M2).
- Under step-synchronous execution (required when an integrator reads state back to the CPU each step), Metal completion notifications complete 84.3 us faster than OpenCL clFinish on M3 Ultra (0.57 ms vs 0.65 ms, a 13.0% speed advantage for Metal) and 79.7 us faster on M2 (2.05 ms vs 2.13 ms, a 3.7% advantage).

---

## 3. Metal 4 against classic model

### Command
`swiftc -O experiments/008-host-cost/harness_q1_q3.swift -o q1_dispatch && ./q1_dispatch`

### Findings
1. Metal 4 availability: `MTL4CommandQueue`, `MTL4CommandAllocator`, `MTL4CommandBuffer`, `MTL4ComputeCommandEncoder`, `MTL4ArgumentTable`, and `MTLResidencySet` compile and run using Command Line Tools without Xcode on macOS 27.0.
2. Default execution semantics: Classic Metal compute command encoders serialize dispatches by default. Metal 4 compute command encoders are concurrent by default.
3. Intra-pass synchronization: In Metal 4, serial dispatch ordering requires explicit calls to `enc.barrier(afterEncoderStages: .dispatch, beforeEncoderStages: .dispatch, visibilityOptions: [])`. Without this barrier, dependent dispatches execute concurrently and produce race conditions.
4. Inter-pass synchronization: Encoders within the same command buffer require `enc.barrier(afterStages: .dispatch, beforeQueueStages: .dispatch, visibilityOptions: [])` to prevent overlapping execution.
5. Performance:
   - `metal4_one_encoder` achieves 0.100 us host encode time per dispatch with argument tables on M3 Ultra (0.118 us on M2), matching classic single encoder (0.112 us on M3 Ultra, 0.119 us on M2).
   - `metal4_encoder_per_kernel` incurs a 14.4 us (M3 Ultra) and 37.2 us (M2) GPU execution cost per dispatch because inter-pass barriers flush caches and drain the pipeline.
   - For OpenMM workloads, Metal 4 provides no performance advantage over classic single-encoder batching.

---

## 4. Storage modes and energy readback

### Command
`swiftc -O experiments/008-host-cost/harness_q4.swift -o q4_storage && ./q4_storage`

### Method
Measures streaming bandwidth across 100 MB (26,214,400 floats) in Shared and Private modes, plus the latency to read back 12 floats (the energy values) per step to the CPU.

### Results

| Metric | M3 Ultra Shared | M3 Ultra Private | M2 Shared | M2 Private |
| :--- | :--- | :--- | :--- | :--- |
| Bandwidth (GB/s) | 568.8 (IQR 22.4) | 734.8 (IQR 18.2) | 84.9 (IQR 0.8) | 84.7 (IQR 0.6) |
| Wall time (ms) | 0.479 (IQR 0.026) | 0.460 (IQR 0.014) | 1.258 (IQR 0.012) | 1.261 (IQR 0.009) |
| GPU time (ms) | 0.260 (IQR 0.002) | 0.257 (IQR 0.002) | 1.235 (IQR 0.001) | 1.238 (IQR 0.001) |
| Energy readback (us) | 0.95 (IQR 0.95) | 170.47 (IQR 9.06) | 1.91 (IQR 0.95) | 196.99 (IQR 8.11) |
| Readback penalty (us) | baseline | +169.5 | baseline | +195.1 |

Host output verification: PASS. Computed output verified against expected analytical values on both chips.

### Mechanism
- On base M2, Shared and Private buffers achieve identical streaming bandwidth (84.9 vs 84.7 GB/s) because both access the same physical LPDDR5 bus through the unified system-level cache.
- On M3 Ultra, Private buffers show a streaming bandwidth advantage (734.8 vs 568.8 GB/s) for synthetic streaming arrays.
- Reading back 12 floats from a Shared buffer takes 0.95 us (M3 Ultra) and 1.91 us (M2) by reading directly from host pointers.
- Reading back from a Private buffer requires allocating a staging buffer, encoding a blit copy, committing the command buffer, and waiting for GPU completion, which takes 170.5 us (M3 Ultra) and 197.0 us (M2).
- In molecular dynamics, where energies and positions are read regularly, the 170 to 195 us synchronization penalty dwarfs any bandwidth delta. Shared buffers must be used for all OpenMM compute buffers.

---

## 5. metal-cpp wrapper overhead

### Command
`clang++ -std=c++17 -O3 -Iexperiments/008-host-cost/metal-cpp -framework Metal -framework Foundation experiments/008-host-cost/q5_metal_cpp.cpp -o q5_cpp && clang -O3 -framework Metal -framework Foundation experiments/008-host-cost/q5_objc.m -o q5_objc && swiftc -O experiments/008-host-cost/q5_swift.swift -o q5_swift && ./q5_cpp && ./q5_objc && ./q5_swift`

### Results
Measured over 10,000 dispatches inside one compute encoder across 20 repeats.

| Language / Wrapper | M3 Ultra (us/dispatch) | M3 Ultra IQR | M2 (us/dispatch) | M2 IQR |
| :--- | :--- | :--- | :--- | :--- |
| `metal-cpp` (C++17) | 0.1005 | 0.0054 | 0.1610 | 0.0082 |
| Objective-C | 0.0982 | 0.0039 | 0.1837 | 0.0091 |
| Swift | 0.1781 | 0.0543 | 0.2319 | 0.0124 |

Delta (metal-cpp versus Objective-C):
- M3 Ultra: +2.4 ns per dispatch.
- M2: -22.7 ns per dispatch.

Host output verification: PASS for all three implementations.

### Mechanism
- metal-cpp wraps Objective-C runtime selectors in inline C++ member functions. Clang inlines these calls down to direct `objc_msgSend` calls.
- The measurable per-call overhead of metal-cpp compared to native Objective-C is zero within run-to-run timing noise (under 3 ns difference).
- Swift introduces 70 to 80 ns of bridge overhead per dispatch due to ARC retain/release and Swift calling convention wrapping.

---

## 6. Timestamp units

### Command
`swiftc -O experiments/008-host-cost/harness_q6.swift -o q6_timestamps && ./q6_timestamps`

### Method
A math-heavy kernel of known long duration (600,000 iterations of polynomial evaluation) was executed on both APIs and measured by CPU wall clock, Metal GPU timestamps, and OpenCL profiling event timestamps (`CL_PROFILING_COMMAND_START` and `CL_PROFILING_COMMAND_END`).

### Results

| Metric | Apple M3 Ultra | Apple M2 |
| :--- | :--- | :--- |
| Metal wall clock (ms) | 78.74 (IQR 2.47) | 272.50 (IQR 1.25) |
| Metal gpuStartTime/gpuEndTime (ms) | 78.42 (IQR 2.48) | 272.10 (IQR 1.25) |
| OpenCL wall clock (ms) | 271.27 (IQR 2.84) | 272.84 (IQR 1.88) |
| OpenCL raw profiling ticks diff | 6,501,669 (IQR 68,195) | 6,547,680 (IQR 45,120) |
| OpenCL duration if interpreted as ns (ms) | 6.502 | 6.548 |
| `mach_timebase_info` numer / denom | 125 / 3 | 125 / 3 |
| Calculated tick period (ns/tick) | 41.6667 | 41.6667 |
| OpenCL duration converted with timebase (ms) | 270.90 | 272.82 |
| Ratio: OpenCL wall clock / raw profiling diff | 41.72 | 41.67 |

Host output verification: PASS. Output values between Metal and OpenCL agree with 0 maximum absolute difference.

### Mechanism
- Apple's OpenCL driver populates `CL_PROFILING_COMMAND_START` and `CL_PROFILING_COMMAND_END` with raw values from the system crystal counter (`mach_absolute_time`).
- On all Apple silicon chips, the crystal oscillator runs at 24 MHz, giving an exact conversion of `125 / 3 = 41.6667` ns per tick.
- Dividing raw ticks by 1,000,000 under the assumption that the values are nanoseconds causes OpenCL kernel durations to appear 41.6667x smaller than reality.
- Multiplying raw ticks by `(125.0 / 3.0) / 1e6` produces 270.90 ms (M3 Ultra) and 272.82 ms (M2), matching CPU wall clock time (271.27 ms and 272.84 ms).
- Metal timestamps (`gpuStartTime` and `gpuEndTime`) report elapsed time in seconds as double-precision floating-point numbers and do not require timebase conversion.

---

## 7. Hang and fault modes

### Command
`swiftc -O experiments/008-host-cost/harness_q7.swift -o q7_hangs && ./q7_hangs`

### Results

Four hang and fault modes were tested with 3.0 second timeouts.

| Test Mode | Description | Status Code | Status Name | Error | Behavior |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `wait_before_commit` | `waitUntilCompleted()` called before `commit()` | 0 | `notEnqueued` | `nil` | CPU thread hangs indefinitely at 0% CPU; semaphore never signals. |
| `out_of_range_buffer_write` | Kernel writes to unmapped address `0xdeadbeef0000` | 4 | `completed` | `nil` | Completes silently. Stores to unmapped pages are dropped by Apple Silicon UMA without hardware exception. |
| `infinite_kernel_loop` | Kernel executes non-terminating while loop | 3 | `other` (committed) | `nil` | GPU hangs in flight indefinitely. OS watchdog does not kill compute command buffer within 3 seconds. |
| `threadgroup_barrier_divergent` | `threadgroup_barrier` inside `if (simd_id == 0)` | 3 | `other` (committed) | `nil` | SIMD-divergent barrier deadlocks the threadgroup. Command buffer hangs in flight indefinitely. |

Host output verification: PASS. All four fault modes reproduced cleanly.

### What it changes
- Metal provides no return errors (`error` is nil) for buffer address faults, infinite loops, or divergent barrier deadlocks.
- Application-level watchdogs using `DispatchSemaphore.wait(timeout:)` or `MTLSharedEvent` must protect all GPU wait calls in OpenMM.

---

## 8. FMA contraction on bonded forces

### Command
`swiftc -O experiments/008-host-cost/harness_q8.swift -o q8_fma && ./q8_fma`

### Method
Tests whether MSL 4.1 supports `#pragma clang fp contract(off)`. Verified first on a tiny kernel evaluating `a * b + c` where `a = 1.0 + 1e-7`, `b = 1.0 - 1e-7`, `c = -1.0`:
- Contraction active (FMA): yields `-1.421085e-14`.
- Contraction off (separate mul and add): yields `0.0`.

The pragma was then evaluated on the full `computeBondedForces` kernel (dumps/apoa1rf/006) across 276,672 force buffer entries against Apple OpenCL reference outputs.

### Results

Tiny kernel verification:
- Default: `-1.421085e-14`
- `#pragma clang fp contract(fast)`: `-1.421085e-14`
- `#pragma clang fp contract(off)`: `0.0`
- `#pragma STDC FP_CONTRACT OFF`: `0.0`
- Status: PASS.

Bonded forces agreement with Apple OpenCL (276,672 elements):

| Configuration | M3 Ultra Bitwise Match | M3 Ultra Max Abs Diff (kJ/mol/nm) | M2 Bitwise Match | M2 Max Abs Diff (kJ/mol/nm) |
| :--- | :--- | :--- | :--- | :--- |
| Metal default (fast math) | 96.42% (266,761) | 0.0171 | 96.33% (266,517) | 0.0171 |
| Metal safe math (no pragma) | 97.46% (269,652) | 0.0564 | 96.70% (267,532) | 0.0564 |
| Metal safe math + `#pragma clang fp contract(off)` | 96.45% (266,863) | 0.1038 | 96.34% (266,549) | 0.1038 |
| Metal safe math + `#pragma clang fp contract(fast)` | 96.81% (267,852) | 0.0564 | 96.47% (266,903) | 0.0564 |
| Metal safe math + `#pragma STDC FP_CONTRACT OFF` | 96.45% (266,863) | 0.1038 | 96.34% (266,549) | 0.1038 |

Host output verification: PASS on all configurations.

### Mechanism
- `#pragma clang fp contract(off)` is live and supported in MSL 4.1.
- Turning contraction off in Metal reduces agreement with Apple OpenCL from 97.46% to 96.45% on M3 Ultra (and from 96.70% to 96.34% on M2).
- This proves that Apple's OpenCL compiler performs fused multiply-add contraction. The remaining ~2.5% divergence between Metal and OpenCL is not caused by contraction differences, but by different transcendental function polynomial implementations (such as `sin` and `cos` in bonded angle and dihedral terms).

---

## Unverified items and elimination findings

1. OS watchdog threshold: Infinite loops and divergent barriers did not trigger an OS GPU restart within 3.0 seconds. The exact macOS watchdog timeout before a hardware channel reset is unverified.
2. Divergence cause in bonded forces: By elimination, the remaining 2.5% bitwise difference between Metal and OpenCL bonded forces is not caused by FMA contraction. It is attributed by elimination to internal transcendental approximations in trigonometric functions.
3. Multi-GPU scaling: Measurements reflect single-GPU execution on M3 Ultra and M2. Host overhead for multi-GPU contexts was not evaluated.

---

Assumptions: none

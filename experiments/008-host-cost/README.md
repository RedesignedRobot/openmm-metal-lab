# Experiment 008: Host side cost of a Metal platform

## Question

What does the host side of a Metal platform cost per molecular dynamics step on Apple silicon, and how should OpenMM batch its GPU commands to minimize overhead?

OpenMM launches 30 to 60 small kernels per step. On an Apple M2 under OpenCL, an ApoA1 step takes 4.9 ms. Dispatch latency decides whether a native Metal platform can outperform OpenCL.

This experiment answers eight questions:
1. Per-dispatch host encode, schedule, and execution costs across batching models.
2. Step workload replay using 50 dispatches of real OpenMM kernels for 1000 steps.
3. Metal 4 API viability and performance without Xcode.
4. Shared versus private storage mode bandwidth and energy readback penalties.
5. metal-cpp wrapper overhead compared to Objective-C and Swift.
6. Timestamp units and the 41.7x OpenCL profiling discrepancy.
7. Hang and fault reproduction modes in Metal compute.
8. Fused multiply-add contraction behavior in MSL 4.1.

## Method

All harnesses are written in Swift, C++ (metal-cpp), and Objective-C. Tests run on two machines:
- Apple M3 Ultra, macOS 27.0, build 26A428 (local Mac).
- Apple M2, macOS 27.0, build 26A428 (remote Mac mini via mini.sh).

Every timed kernel produces output that depends on its input and is validated on the host. Timings report medians and interquartile ranges over at least 20 repeats. All GPU waits use explicit timeouts.

Execution commands:
- Full matrix gate: `sh experiments/008-host-cost/run.sh`
- Q1 and Q3: `swiftc -O experiments/008-host-cost/harness_q1_q3.swift -o q1_dispatch && ./q1_dispatch`
- Q2: `swiftc -O experiments/008-host-cost/harness_q2.swift -o q2_step && ./q2_step`
- Q4: `swiftc -O experiments/008-host-cost/harness_q4.swift -o q4_storage && ./q4_storage`
- Q5: `clang++ -std=c++17 -O3 -Iexperiments/008-host-cost/metal-cpp -framework Metal -framework Foundation experiments/008-host-cost/q5_metal_cpp.cpp -o q5_cpp && ./q5_cpp`
- Q6: `swiftc -O experiments/008-host-cost/harness_q6.swift -o q6_timestamps && ./q6_timestamps`
- Q7: `swiftc -O experiments/008-host-cost/harness_q7.swift -o q7_hangs && ./q7_hangs`
- Q8: `swiftc -O experiments/008-host-cost/harness_q8.swift -o q8_fma && ./q8_fma`

## Result

Detailed numerical results and comparative tables are recorded in results.md, results-m3ultra.json, and results-m2.json.

Summary of findings:
- Dispatch batching: Creating one command buffer per kernel incurs 15.1 us (M3 Ultra) and 23.6 us (M2) of host encode overhead per dispatch. Consolidating dispatches into one serial encoder drops host overhead to 0.11 us per dispatch on both chips, 3.4x faster than OpenCL clEnqueueNDRangeKernel (0.38 us).
- Step replay: Replaying 50 dispatches of real OpenMM kernels for 1000 steps on 92,224 atoms takes 0.33 ms/step on M3 Ultra and 1.78 ms/step on M2 when pipelined, matching OpenCL. When synchronizing per step, Metal is 13.0% faster than OpenCL on M3 Ultra (0.57 ms vs 0.65 ms) and 3.7% faster on M2 (2.05 ms vs 2.13 ms).
- Metal 4: Metal 4 compute runs using Command Line Tools without Xcode. Compute encoders are concurrent by default and require explicit intra-pass barriers. Metal 4 one encoder matches classic serial encoder host latency (0.10 us). Encoder-per-kernel in Metal 4 suffers heavy GPU pipeline stalls (14.4 us on M3 Ultra, 37.2 us on M2) due to inter-pass barrier flushes.
- Storage modes: Shared buffers achieve 568.8 GB/s on M3 Ultra and 84.9 GB/s on M2. Energy readback of 12 floats in Shared mode takes 0.95 us (M3 Ultra) and 1.91 us (M2). Private mode requires staging blits and GPU completion waits, adding 169.5 us (M3 Ultra) and 195.1 us (M2) penalty per readback.
- Wrapper overhead: metal-cpp has no measurable call overhead over Objective-C (+2.4 ns on M3 Ultra, -22.7 ns on M2). Both are 70 to 80 ns faster than Swift.
- Timestamp units: OpenCL profiling returns raw 24 MHz mach ticks (125/3 = 41.6667 ns/tick). Treating them as nanoseconds created the 41.7x undercounting in experiment 003. Metal reports seconds directly.
- Fault modes: Waiting before commit hangs the host thread indefinitely at 0% CPU with status 0 and error nil. Out of range writes complete silently with status 4 and error nil. Infinite loops and divergent barriers hang the GPU indefinitely with status 3 and error nil.
- FMA contraction: MSL 4.1 honors `#pragma clang fp contract(off)`. Disabling contraction reduces bitwise agreement with Apple OpenCL from 97.46% to 96.45% on M3 Ultra, proving Apple's OpenCL compiler contracts multiply-add operations.

## What it changes

1. OpenMM Metal architecture: The host platform must encode all kernels of a step into a single command buffer using one compute command encoder. One command buffer per kernel is not viable.
2. Buffer design: OpenMM must use Shared storage mode for all dynamic buffers. Private buffers offer zero bandwidth advantage on base M2 and add a 170 to 195 us synchronization penalty to every CPU readback.
3. Language choice: metal-cpp satisfies the C++ requirement with zero per-dispatch penalty compared to Objective-C.
4. Profiling correction: Profiling event durations in OpenMM OpenCL on Apple silicon must be multiplied by 125/3 (41.6667) to convert ticks to nanoseconds.
5. Metal 4 adoption: Metal 4 does not require Xcode, but provides no latency advantage over classic Metal 3 single-encoder batching for MD step workloads. Classic Metal should be the primary target.

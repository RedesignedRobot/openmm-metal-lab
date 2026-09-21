# Head's note on 008

Accepted. The main result is a negative one and it is useful: the host side is not where a Metal platform wins or loses against OpenCL.

- Batching decides everything. One command buffer per kernel costs 15 us (M3 Ultra) to 24 us (M2) of host time per dispatch; one encoder for the whole step costs 0.11 us, against 0.38 us for clEnqueueNDRangeKernel. This also audits the research note's "10 to 25 microseconds per dispatch": true only for the worst batching.
- A step-shaped replay (50 real kernels, 92,224 atoms, 1000 steps) runs at the same speed on both APIs when pipelined: 1.790 ms against 1.779 ms on the M2. With a wait every step Metal is 4% ahead on the M2. Any speedup over OpenCL has to come from the kernels (009 to 011), which is what peastman and philipturner said.
- metal-cpp costs nothing over Objective-C (within 25 ns per dispatch, either sign). The maintainers' C++ requirement is free.
- Metal 4 works from the Command Line Tools and gives no gain for this workload; its encoders need explicit barriers. The classic model is enough, and it keeps macOS 14 as the floor.
- Shared buffers: reading 12 floats back costs 1 to 2 us, against 170 to 197 us from a private buffer. Streaming bandwidth is the same on the M2. Use shared for anything the host reads.
- Apple's OpenCL profiling events are mach ticks, 125/3 ns each, confirmed to 0.1% on both chips. Experiment 003's fractions stand; its absolute times need multiplying by 41.67.
- `#pragma clang fp contract(off)` is live in MSL 4.1 and makes agreement with OpenCL worse, so OpenCL contracts too. Contraction is not the cause of the residue.

Head's checks and caveats:

- The lane waited 3 s before calling a spinning kernel a permanent hang. The head's probe (`experiments/004-msl-probes/gpu-watchdog.swift`) waited 120 s on each chip: the command buffer stays at status 3 with no error on both. macOS does not rescue a compute process from a runaway kernel in any useful time, so a Metal platform needs its own timeout. The first attempt at that probe ended in 0.0 s because the compiler deleted a side-effect-free infinite loop; a kernel that "cannot hang" in a test may have been optimised away.
- Out-of-range writes complete with no error. Metal gives a port no fault signal; the shader validation layer (MTL_SHADER_VALIDATION=1) is the tool for that and is untested here.
- Wait before commit blocks forever with status 0. That matches what 006's first harness showed and is the likely cause of that hang. Not proven, the lane never said.
- The bonded agreement baseline moved between experiments: 95.1% in 007, 97.5% here, both labelled safe math on the M3 Ultra. The two harnesses differ in some setting the reports do not name. The physics is unaffected (energy agrees to 17 ppb), but no percentage from this series goes upstream until one harness reproduces both numbers.
- "The residue comes from trigonometric approximations" is by elimination and contradicts 007, where asin and acos matched bit for bit under safe math. Still open. cos, sin and atan2 were never swept.

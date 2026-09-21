# Head note on 010c

Target missed, data accepted. No formulation brings Metal-native computeNonbonded to OpenCL speed on the M2.

M2, forces-only, matched clocks: OpenCL 2.664 ms (rf) and 2.530 ms (pme). Best Metal-native 2.873 and 2.808 ms, so Metal is 8 and 11% behind. With the exclusion loop skipped on both sides Metal leads on rf (2.420 against 2.490 ms) and trails by 1% on pme. The whole deficit sits in the exclusion tile loop: 0.46 ms on Metal against 0.17 ms on OpenCL. Four rewrites of that loop and one write-back change moved it by at most 0.01 ms.

M3 Ultra: the 010b native baseline stays the best at 0.621 ms against 1.046 ms for OpenCL, 1.68x. Every 010c variant is slower there, so none is adopted.

Struck as untested: "pipeline stalls" from barriers, "hardware predication", "memory crossbar contention" and "Dynamic Caching". The lane ran no ablation that isolates any of them. Why Apple's OpenCL compiler runs the same exclusion loop 0.29 ms faster on the M2 is unexplained, and the compiled code cannot be read (004, opencl-binary).

This line of work stops here. An 8 to 11% deficit in one kernel on the smallest chip does not decide anything upstream, and the neighbour-list gain in 009 more than covers it per step.

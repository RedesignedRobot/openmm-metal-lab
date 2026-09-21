# 004: MSL probes run on both chips

Small Swift programs that compile MSL at runtime and execute it. The head wrote them to check claims made by the census lane (002) and the two research lanes (docs/metal). Build each with `swiftc -O <file> -o probe && ./probe`. Default compile options, macOS 27.0, so the newest MSL version.

| Probe | Question | M2 (mini) | M3 Ultra (head's Mac) |
| --- | --- | --- | --- |
| `program-scope-builtins.swift` | Can `[[thread_position_in_grid]]` and friends be declared as program-scope variables and read from a helper function, so `GLOBAL_ID` stays a parameterless macro? | Yes, 1000 of 1000 values right | Yes |
| `simd-ballot.swift` | Does `simd_ballot` exist in MSL? | Compiles | Compiles |
| `atomics-compile.swift` | Which atomics build into a pipeline? | `atomic<float>` add, exchange, compare-exchange: yes. `atomic<ulong>` fetch_add and fetch_max: no matching function | Same on both counts |
| `float-atomic-contention.swift` | Is `atomic<float>` fetch_add correct, and what does it cost under worst-case contention (2^20 threads adding into 8 cells)? | Correct sums. 190.8 ms GPU time | Correct sums. 0.34 ms GPU time |

## What it changes

- Program-scope builtins remove the largest expected source incompatibility. OpenMM's Common kernels call `GLOBAL_ID` with no argument from anywhere; MSL can serve that without touching kernel signatures. The MSL note cites the specification for this (Metal 3.1 and later, section 5.2).
- peastman's "ballot" is real: `simd_ballot`. Common kernels already have a `BALLOT` path behind `USE_HIP` (lcpo.cc, customManyParticle.cc).
- Float atomics work on the M2, against what the upstream thread assumed. The contention probe shows a 560 times gap to the M3 Ultra where core count explains about 8 times. The likely reason is a compare-exchange loop on the M2 against a hardware path on the M3 family. Unverified. The probe is the worst case; PME charge spreading puts about 92,000 atoms onto a grid of a million or more cells, so contention there is low. The experiment that settles it: a float-atomic gridSpreadCharge against the fixed-point one, on the M2, with the real ApoA1 atom distribution.
- 64-bit atomics: the API note claims `atomic<ulong>` min and max exist on Apple8 and full arithmetic on Apple9. Neither compiled on either chip with the obvious function names. Treat 64-bit atomics as unavailable until someone shows a program that builds.

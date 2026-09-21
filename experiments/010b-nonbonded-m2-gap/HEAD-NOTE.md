# Head's note on 010b

Accepted as a partial answer. cdx flagged the round failed only because run.sh rewrites a results file during the gate; the gate exited 0.

What it established:

- Experiment 010's M2 comparison was unfair, and the numbers show it: 010 timed OpenCL's forces-only program against Metal programs compiled with energy accumulation. 010's figures reappear here exactly in those two columns (OpenCL 2.66 ms forces-only, native 3.24 ms with energy, apoa1rf). Like for like on the M2, forces-only, the kind of step a simulation runs most: OpenCL 2.66 (rf) and 2.53 (pme); native 2.89 and 2.83; translation 3.10 and 2.98. So Metal is 8% to 12% slower than OpenCL on the M2, not 18%. With energy: within 1% on pme, 7% slower on rf.
- The native kernel loses its time in the exclusion tile loop. With that loop removed the native kernel is faster than OpenCL on the M2 (2.42 against 2.49 ms); the loop costs the native kernel 0.46 ms and OpenCL 0.17 ms. 5,213 of the tiles go through it. That is a concrete target.
- The split-word atomic write-back costs about 0.4 ms on either API (15% of the kernel). Fixed-point conversion costs nothing measurable.
- `optimizationLevel = .size` gave the best native time on the M2, 2.82 ms.

What it did not establish:

- Why the straight translation of identical source is 12% to 17% slower than OpenCL on the M2. The ablation switches were never applied to the translation or to OpenCL for cases (e) and (f): those rows repeat the baseline. The brief's first line of attack, comparing compiled code, was skipped by the lane. The head tried it (`experiments/004-msl-probes/opencl-binary.swift`): Apple's OpenCL returns a property list holding source and options, no compiled code. Dead end without Apple's tools.
- "Memory bandwidth binds the kernel". The memory-only and arithmetic-only ablations are too crude to carry that; treat it as a lead.
- Struck: "Dynamic Caching" and "OpenCL starves 50 of 60 cores on the M3 Ultra". No measurement separates those causes. The M3 Ultra numbers also moved by 20% between the lane's two runs, because the head's Mac was in use. Only the M2 numbers from this experiment are fit to quote.

Where that leaves the maintainer's condition: on the M2, NonbondedForce through Metal does not beat OpenCL yet on the kernel alone. The neighbour list (009) wins by 2.3x and the two kernels together are what NonbondedForce costs, so the combined figure favours Metal: per rebuild-plus-force on apoa1rf, OpenCL 4.64 + 2.66 = 7.30 ms against Metal 1.99 + 2.89 = 4.88 ms, 1.5x. The neighbour list does not rebuild every step, so the real ratio sits between 0.92x and 1.5x depending on rebuild frequency, which 003's profile can bound. The exclusion loop is the next kernel target, after PME.

# Experiment 010b: computeNonbonded M2 gap investigation

This experiment investigates why `computeNonbonded` appeared slower on Metal than Apple OpenCL on Apple M2 in experiment 010, whereas on Apple M3 Ultra Metal Native ran 1.6x faster than OpenCL.

## Key findings

1. In experiment 010, OpenCL compiled without energy calculation (`INCLUDE_ENERGY` undefined), while Metal compiled with energy calculation (`INCLUDE_ENERGY = 1`). Evaluating energy requires extra pairwise potential math, reductions, and atomic writes to global memory. Under identical energy compilation flags on M2, Metal Native matches OpenCL within 0.9% on PME (3.0329 ms vs 3.0056 ms).
2. Removing Loop 1 (exclusion handling) in ablation (c) makes Metal Native faster than OpenCL on M2 (2.4218 ms vs 2.4893 ms on apoa1rf). Metal Native's main pairwise interaction loop (Loop 2) is already faster than OpenCL on M2.
3. On M3 Ultra, Metal Native runs 1.68x to 2.37x faster than OpenCL across all configurations. OpenMM's OpenCL sizing dispatches 60 blocks, which saturates M2 (10 cores) but starves 50 of the 60 cores on M3 Ultra.
4. Memory bandwidth and 64-bit atomic write-back account for >70% of execution time on M2. Fixed-point conversion overhead is negligible (<0.02 ms).

## How to run

### Local run (Apple M3 Ultra)

Execute the gate script directly:

```sh
sh experiments/010b-nonbonded-m2-gap/run.sh
```

This compiles `harness.swift` with `swiftc -O`, validates numerical forces within 10.0 ppm tolerance against recorded reference forces, verifies mutation detection gates, runs standalone parity benchmarks and the ablation matrix, and writes `results-m3ultra.json`.

### Remote run on Apple M2

Run the gate script on the Apple M2 mini via the lab script:

```sh
./mini.sh experiments/010b-nonbonded-m2-gap "sh run.sh"
```

This syncs the directory, builds the harness on the M2, verifies agreement, runs benchmarks, and writes `results-m2.json`.

### Standalone ablation suite

To run only the standalone ablation matrix:

```sh
swift experiments/010b-nonbonded-m2-gap/run_ablation.swift
```

Or on the M2:

```sh
./mini.sh experiments/010b-nonbonded-m2-gap "swift run_ablation.swift"
```

## Directory contents

- `run.sh`: Gate script compiling and executing the benchmark harness.
- `harness.swift`: Unified verification and benchmark suite for agreement, parity, and ablations.
- `run_ablation.swift`: Standalone ablation runner evaluating OpenCL, Metal Translation, and Metal Native.
- `kernels/`: Metal and OpenCL kernel definitions including prelude and ablation hooks.
- `results-m2.json`: Benchmark output recorded on Apple M2 (macOS 27.0.0 Build 26A428).
- `results-m3ultra.json`: Benchmark output recorded on Apple M3 Ultra (macOS 27.0.0 Build 26A428).
- `results.md`: Full investigation report with measurements, hardware comparison, and architectural analysis.

## Assumptions

none

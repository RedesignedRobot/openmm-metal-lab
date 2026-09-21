# Experiment 010c: computeNonbonded exclusion loop formulations

This experiment evaluates four distinct exclusion loop formulations and a write-back alternative to close or isolate the remaining runtime gap between Metal Native and Apple OpenCL on the Apple M2 for `apoa1rf` and `apoa1pme`.

## Key findings

1. Loop 2 (pairwise neighbor list interactions) is faster in Metal Native than in Apple OpenCL on Apple M2 (2.420 ms vs 2.490 ms on apoa1rf). The performance difference is confined entirely to Loop 1 (exclusion handling), which takes 0.461 ms in Metal Native vs 0.174 ms in OpenCL.
2. Emulating OpenCL verbatim with threadgroup local memory (Formulation 1) regresses performance significantly on Apple Silicon (4.593 ms on M2 apoa1rf). Metal threadgroup memory requires execution barriers between iterations to prevent read-after-write hazards across SIMD lanes, causing pipeline stalls.
3. Formulation 2 (separate exclusion kernel dispatched on its own grid of 5,213 single-tile threadgroups) executes in 2.932 ms on apoa1rf. The exclusion kernel completes in 0.48 ms, and the interaction kernel completes in 2.42 ms.
4. Formulation 3 (branch-free masked accumulation) runs in 2.933 ms on apoa1rf. Branch divergence in exclusion tiles is handled efficiently by Apple Silicon hardware predication, so unconditional arithmetic adds ALU cycles without reducing latency.
5. Formulation 4 (tile-size specialized x4 unrolling) runs in 2.902 ms on apoa1rf.
6. The Write-back Alternative (accumulating atom1 forces across contiguous exclusion tiles in registers before performing 64-bit atomic writes with carry optimization) achieves 2.873 ms on apoa1rf and 2.808 ms on apoa1pme, the fastest monolithic kernel time recorded on M2.
7. The remaining ~0.20 ms exclusion gap on M2 is bound by 64-bit split-word atomic write contention across scattered atom indices on the 10-core GPU memory crossbar. On M3 Ultra (60 GPU cores, Dynamic Caching), Metal Native is 1.68x faster than OpenCL (0.621 ms vs 1.046 ms on apoa1rf).

## How to run

### Local run (Apple M3 Ultra)

Execute the gate script:

```sh
sh experiments/010c-nonbonded-exclusions/run.sh
```

This compiles `harness.swift`, validates force agreement within 10.0 ppm tolerance, verifies mutation gate detection, executes 25-run benchmarks for all ablations, and writes results to `/tmp/results-010c.json`.

To write directly to the repository results file:

```sh
swiftc -O experiments/010c-nonbonded-exclusions/harness.swift -o experiments/010c-nonbonded-exclusions/harness
experiments/010c-nonbonded-exclusions/harness --out experiments/010c-nonbonded-exclusions/results-m3ultra.json --captures-dir experiments/010-compute-nonbonded/captures --kernels-dir experiments/010c-nonbonded-exclusions/kernels
```

### Remote run on Apple M2

Run the gate script on the Apple M2 mini via the lab script:

```sh
./mini.sh experiments/010c-nonbonded-exclusions "sh run.sh"
```

Or execute the harness directly on the remote host:

```sh
ssh "$MINI" "~/lab/010c-nonbonded-exclusions/harness --out ~/lab/010c-nonbonded-exclusions/results-m2.json --captures-dir ~/lab/010-compute-nonbonded/captures --kernels-dir ~/lab/010c-nonbonded-exclusions/kernels"
```

## Directory contents

- `run.sh`: Gate script executing verification and benchmarking.
- `harness.swift`: Unified verification and benchmark harness supporting OpenCL and Metal Native formulations.
- `kernels/computeNonbonded_native.metal`: Metal kernel implementing baseline, four exclusion formulations, write-back alternatives, and mutation hooks.
- `kernels/computeNonbonded_rf.cl`: Reference OpenCL kernel.
- `results-m2.json`: Benchmark and agreement data recorded on Apple M2 mini (macOS 27.0.0 Build 26A428).
- `results-m3ultra.json`: Benchmark and agreement data recorded on Apple M3 Ultra Mac Studio (macOS 27.0.0 Build 26A428).
- `results.md`: Complete report with measurements, hardware comparison, ablation tables, and architectural analysis.

## Assumptions

none

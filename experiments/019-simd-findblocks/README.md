# Experiment 019: SIMD-group findBlocksWithInteractions in the Metal platform

## Question

The Metal platform's neighbour list kernel, `findBlocksWithInteractions`, was a translation of the OpenCL kernel, which shares flags and prefix sums through threadgroup memory. If it follows the CUDA kernel instead, using `simd_ballot`, `ctz` and `popcount`, do real simulations get faster on an M2? This is the end-to-end evidence peastman asked for on openmm/openmm#5397. Experiment 009 had already shown that a native kernel is 2.3–3.1x faster in isolation.

## What changed

The change is commit `33728aa53` on branch `metal-simd-findblocks`, based on `metal` at `361452c5c`, in `/Users/amir/code/mini/openmm-simd`. It touches two files: `platforms/metal/src/kernels/common.metal` and `findInteractingBlocks.metal`. The host code and the other kernels are unchanged.

Ported from CUDA's `findInteractingBlocks.cu`:
- Ballots for large-block flags and candidate blocks, walked with `ctz`.
- Ballot and `popcount` compaction in place of the prefix sum.
- `simd_broadcast` for the tile start index.
- A bounding-sphere prefilter from each atom of block X to block Y, with the `first..last` j range when the periodic box is too small for a single periodic copy.
- The `halfDist2` trick: `w` holds half the squared norm of the position.
- `forceInclude` for triclinic boxes.

Deliberately not ported:
- Single pairs: the Metal nonbonded kernel does not consume them.
- half3 bounding boxes.

Threadgroup memory drops from 14.2–14.5 KB to 12.9 KB. GROUP_SIZE stays 256. Every cross-lane read of threadgroup memory is behind `SYNC_WARPS`, rather than relying on lockstep execution. That includes one barrier at the top of the block loop, added after a fresh-context review found a latent write-after-read race there.

## Method

Everything ran on the Mac mini: Apple M2, 10 GPU cores, 8 GB, macOS 27.0 (26A428). Both trees were built with `~/lab/bin/build-openmm.sh` (Release, ccache) into their own prefix and venv. The venvs are identical: Python 3.13.15, numpy 2.5.3, cython 3.3.0. The installed `libOpenMMMetal.dylib` of the after build contains `simd_ballot`; the before build's does not.

1. **Neighbour list set** (`nlcheck.swift`): the ApoA1 captures from experiment 009 (OpenCL reference output), run through each assembled kernel. The dispatch geometry is the platform's: 120 threadgroups × 256 threads. Pairs are compared as `(block, atom)`. For each differing pair, the tool prints its distance from PADDED_CUTOFF in double. It also times the kernel alone with command-buffer GPU timestamps, 20 repeats.
2. **Forces and energies** (`eqcheck.py`, `compare.py`): 7 systems, each evaluated in 2 fresh Contexts per install, in single and mixed precision. The systems are apoa1rf, apoa1pme, pme (dhfr), amber20-cellulose (408,609 atoms, large-block path), and the FAH work units dhfr, nav (173,112 atoms, large-block path) and dhfr in a triclinic box. The before-vs-before difference is the rounding floor.
3. **ctest**: `ctest -R TestMetal --timeout 1800` on the after build tree. This covers 110 tests, both precisions.
4. **Speed** (`run.py`): the unmodified `benchmark.py` (sha256 `cb2dec8f…`, same as `bench-018` and the 361452c5c source), run from a copy of `examples/benchmarks` with `--platform=Metal`. Tests are pme, apoa1rf, apoa1pme and amber20-cellulose, in single and mixed. The FAH dhfr and nav work units run through `fahwu.py` for 60 s. Three rounds, all at nice 0, on AC power.
   - Within a round, each (test, precision) pair runs before and after back to back, and which install goes first alternates.
   - **Clock:** `benchmark.py`'s own host wall clock (`datetime.now`, whole steps, after its warm-up); `fahwu.py` uses host wall `time.perf_counter`.
   - The mini is shared with other agents. Each pair held the machine lease `/tmp/openmm-lease`, so nothing else ran during a pair. One scheduled pause, 16:03–16:13Z, fell between pairs (`results/yield-boundary.log`).
   - An earlier attempt overlapped two `run.py` processes. All of its data was discarded; it is archived on the mini as `~/lab/simd-019/bench-contaminated-20260923T1558Z` and not used here. The run reported below is a single clean run, 15:59–17:41Z.
5. **findBlocks share** (`fbshare.py`, `fb.sh`): copies of both trees with the scratch patch `time-findblocks.patch`, built into separate prefixes. The patch is never committed anywhere. It puts findBlocks in its own command buffer and logs that buffer's GPU time.
   - `fbshare.py` builds each benchmark system the way `benchmark.py` does, runs 200 warm-up steps, then times 1000 steps.
   - **Clocks:** host wall (`perf_counter`) for steps; GPU timestamps for findBlocks.
   - One run per cell. The extra command buffer boundary perturbs the step slightly, so treat the shares as estimates.

## Results

### Correctness

**Neighbour list set vs the OpenCL reference** (`results/correctness/nlcheck-*.txt`):

| Capture | Kernel | Tiles | Pairs | Missing | Extra | Max \|distance − PADDED_CUTOFF\| of differing pairs | GPU ms median (min–max, n=20) |
| :--- | :--- | ---: | ---: | ---: | ---: | ---: | ---: |
| apoa1rf | before | 55396 | 1727984 | 0 | 0 | – | 4.35 (4.20–6.67) |
| apoa1rf | after | 55396 | 1727988 | 6 | 10 | 1.1e-5 nm | 1.90 (1.85–3.35) |
| apoa1pme | before | 43560 | 1349142 | 0 | 0 | – | 4.05 (3.97–6.96) |
| apoa1pme | after | 43560 | 1349144 | 5 | 7 | 1.2e-5 nm | 2.09 (1.67–2.96) |

- The tiles are identical.
- The few flipped `(block, atom)` pairs all sit within 1.2e-5 nm of the padded cutoff. That is the float rounding of `halfDist2` at the outer edge of the 0.1 nm padding band, and CUDA has the same rounding. None of them is within the real cutoff.

**Forces and energies** (`results/correctness/eq-compare-*.txt`; forces in kJ/mol/nm):

- Forces:
  - Each install gives bitwise-identical forces from one fresh Context to the next.
  - Before vs after, the largest max|dF| is 7.0e-4 (cellulose), and the largest relative |dF| is 5.4e-9, in both precisions.
  - pme gives bitwise-identical forces.
- Energies: every before-vs-after |dE| is within the before-vs-before spread. Outside the triclinic case, that is at most 0.5 kJ/mol on −3.0e6 in single (cellulose, where before-vs-before is also 0.5), and 1e-15 relative in mixed.
- Where the differences come from: the flipped boundary pairs contribute zero force, but they shift atoms between tile columns, which changes float summation order.
- The triclinic case is a deliberately compressed box, so its energy is huge. It is there to exercise `TRICLINIC` and `forceInclude`, and it also matches to rounding.

**ctest** (`results/correctness/ctest.txt`): `100% tests passed out of 110`, 1501 s. This covers the Single and Mixed variants of NonbondedForce, CustomNonbondedForce, CustomGBForce, GBSAOBCForce, CustomManyParticleForce, CustomHbondForce, ATMForce and the rest. The baseline flake, TestMetalLangevinMiddleIntegratorMixed, passed this time.

### Speed, end to end (host wall clock)

`results/summary.md`, raw data in `results/bench/` (json per run, `fah-{before,after}.jsonl`, `runs.jsonl`, `host.txt`).

| Test | Precision | Before ns/day median (min–max, n) | After ns/day median (min–max, n) | After/before |
| :--- | :--- | ---: | ---: | ---: |
| pme | single | 199.69 (199.44–200.16, 3) | 217.15 (216.77–217.24, 3) | 1.087 |
| pme | mixed | 134.75 (134.74–134.90, 3) | 142.55 (142.51–142.93, 3) | 1.058 |
| apoa1rf | single | 58.83 (58.81–58.88, 3) | 73.98 (73.92–73.98, 3) | 1.257 |
| apoa1rf | mixed | 38.98 (38.97–39.00, 3) | 45.13 (45.12–45.20, 3) | 1.158 |
| apoa1pme | single | 46.98 (46.96–47.04, 3) | 56.11 (56.10–56.16, 3) | 1.195 |
| apoa1pme | mixed | 35.04 (35.01–35.05, 3) | 39.98 (39.86–39.99, 3) | 1.141 |
| amber20-cellulose | single | 10.51 (10.51–10.51, 3) | 12.30 (12.25–12.30, 3) | 1.170 |
| amber20-cellulose | mixed | 8.12 (8.10–8.14, 3) | 9.15 (9.15–9.16, 3) | 1.127 |
| FAH dhfr | single | 81.57 (81.52–82.19, 3) | 84.72 (84.56–86.00, 3) | 1.039 |
| FAH dhfr | mixed | 54.50 (54.47–54.59, 3) | 55.64 (55.61–55.80, 3) | 1.021 |
| FAH nav | single | 11.27 (11.27–11.27, 3) | 12.38 (12.37–12.39, 3) | 1.098 |
| FAH nav | mixed | 8.49 (8.49–8.49, 3) | 9.11 (9.10–9.11, 3) | 1.073 |

In every row, the before and after ranges are far apart; none overlap.

### findBlocks share of the step (GPU timestamps for findBlocks, host wall clock for the step)

`results/fb/`, one instrumented run of 1000 steps per cell.

| Test | Precision | Before: findBlocks ms/step, share | After: findBlocks ms/step, share | ms/step before → after |
| :--- | :--- | ---: | ---: | ---: |
| pme | single | 0.337, 19.5% | 0.203, 12.7% | 1.727 → 1.602 |
| pme | mixed | 0.338, 13.1% | 0.200, 8.2% | 2.572 → 2.436 |
| apoa1rf | single | 1.958, 34.4% | 0.870, 18.9% | 5.686 → 4.601 |
| apoa1rf | mixed | 1.943, 22.4% | 0.888, 11.7% | 8.681 → 7.563 |
| apoa1pme | single | 2.023, 27.8% | 0.855, 14.0% | 7.273 → 6.120 |
| apoa1pme | mixed | 2.009, 20.4% | 0.862, 10.1% | 9.834 → 8.570 |
| amber20-cellulose | single | 9.212, 28.0% | 4.328, 15.5% | 32.877 → 28.004 |
| amber20-cellulose | mixed | 9.206, 21.6% | 4.331, 11.7% | 42.547 → 37.608 |

- The list is rebuilt on about half the steps: rebuild fraction 0.44–0.50 at 4 fs. A rebuild takes 1.7x (pme) to 2.4x (apoa1pme) less GPU time after the change: pme 0.67 → 0.40 ms, apoa1pme 4.05 → 1.71 ms, cellulose 18.4 → 8.7 ms. A skipped step costs about 4 µs in both.
- The step-time saving matches the findBlocks saving almost exactly. For apoa1rf single, findBlocks drops by 1.09 ms/step and the step drops by 1.09 ms. So the whole end-to-end gain is this kernel, and nothing else moved.

## Conclusion

- Following the CUDA kernel roughly halves findBlocks GPU time inside real simulations on an M2. That turns into **5.8–25.7% more ns/day** on the four `benchmark.py` tests and 2.1–9.8% on the FAH work units, by host wall clock, median of 3 interleaved rounds with no overlap between before and after.
- The gain is largest where the neighbour list is a large share of the step: apoa1rf at 1.0 nm cutoff, and large systems. It is smallest for dhfr in mixed precision, where integration and PME dominate.
- The neighbour list is equivalent to the old one up to float rounding at the padded-cutoff boundary, and all 110 Metal tests pass.

## Caveats and follow-ups

- **`halfDist2` precision.** `halfDist2` subtracts terms of size |p|²/2, so its absolute error grows with coordinate magnitude. Upstream CUDA has the same property.
  - In periodic systems, coordinates are wrapped near the block centre, and the error is about 1e-5 nm at the padding edge (measured above).
  - For CutoffNonPeriodic systems placed hundreds of nm from the origin, a float emulation by the reviewer showed pairs inside the padding band being dropped. At about 1000 nm it could drop pairs inside the cutoff.
  - A cheap hardening, if upstream wants it, is to subtract `blockCenterX` from both positions before forming `w`.
- **Large-block coverage.** ctest's large system has only 3,200 atoms, so `USE_LARGE_BLOCKS` is exercised here only by cellulose and nav, in eqcheck and the benchmarks. Both match.
- **Not ported:** single pairs (the Metal nonbonded kernel lacks them) and half3 bounding boxes. Either could be a further step.
- **Hardware coverage.** Measured only on M2. The kernel assumes only a SIMD width of 32, which the platform already checks.
- **Instrumentation.** The findBlocks shares come from instrumented builds, one run each. Their ms/step agree with the uninstrumented benchmark to within about 3%, for example apoa1rf single: 5.686 ms instrumented vs 5.875 ms from 58.83 ns/day.

## Files

- **Scripts:**
  - `nlcheck.swift`, `assemble.py`: neighbour list set and GPU time on the 009 captures.
  - `eqcheck.py`, `compare.py`: forces and energies.
  - `run.py`, `fahwu.py`, `summarize.py`: benchmarks and tables.
  - `fbshare.py`, `time-findblocks.patch`, `fb.sh`: findBlocks share (scratch instrumentation).
  - `build.sh`, `pipeline.sh`, `chain.sh`, `lease.sh`: orchestration on the mini.
- **Results:**
  - `results/correctness/`: nlcheck output, eqcheck logs and comparisons, ctest log.
  - `results/bench/`: benchmark JSON and logs.
  - `results/fb/`: fbshare JSON.
  - `results/summary.md`: generated tables.
- **Kept on the mini, not committed:**
  - the eqcheck force arrays: `~/lab/simd-019/eq-*.npz`, 38 MB each;
  - the per-dispatch findBlocks times: `~/lab/simd-019/fb/times-*.txt`.

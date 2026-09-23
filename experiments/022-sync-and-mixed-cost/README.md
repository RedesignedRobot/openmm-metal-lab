# 022: Host syncs and the mixed-precision cost on Metal

Question: what closes the gap between Metal mixed precision (what Folding@home runs) and Apple's
OpenCL single precision? Two candidate fixes were tested on the M3 Ultra (Mac Studio, 60 GPU
cores, macOS 27):

- P2 (`metal-perf-sync` bbf599ddc): CCMA checks convergence without draining the queue. The
  iterations go out in blocks of 4 with an event after each block. The host waits on block k-1
  while the GPU runs block k.
- P3 (`metal-perf-p3-energy-guard`): `#ifdef INCLUDE_ENERGY` around the four `energy += tempEnergy`
  sites in `nonbonded.metal`, so force-only steps stop accumulating energy. The original commit
  5f30ddc82 sits on top of P2 and the profiler, so it was cherry-picked into three local branches:
  `metal-perf-p3-on-base` fab2a3ee3 ("p3"), `metal-perf-p2-p3` 052eaa85b ("p2p3") and
  `metal-perf-p3-profile` 4c1c8b396 ("p3-prof").

The base is `metal` at 361452c5c. The profiler builds are `metal-perf-profile` 32d09490d
("base-prof") and `metal-perf-sync-profile` 08e991c08 ("p2-prof"). OpenCL comes from the Studio's
shared f9347f6c5 install. Work units are the FAHBench ones from experiment 017. "dhfr" means the
FAHBench dhfr work unit, where every bond is constrained and 3,072 non-water constraints go to CCMA.
It is not benchmark.py's HBonds dhfr, which sends nothing to CCMA.

Clocks:
- Speeds are ns/day on the host wall clock: 017's `fahwu.py` times whole steps with
  `time.perf_counter` for 60 s after a 200-step warm-up, and requests the energy every 100 steps.
- Profile numbers come from `OPENMM_METAL_PROFILE`. Blocked waits are on `mach_absolute_time`.
  GPU busy time and gaps come from each command buffer's GPUStartTime/GPUEndTime.

Every build and timed block ran under the Studio lease with owner "perf-studio". Runs were
interleaved, and the run order rotates from round to round. The Studio was not idle: load averages
were 3 to 6, with Virtualization VMs, node and superwhisper using CPU (see `host.txt`).

Full tables: `results/m3ultra-20260923/summary.md`, made by `summarize.py`. Raw JSON lines, ctest
logs and chain logs are next to it. `results/m3pro-20260923T1511Z` is the earlier laptop P1 run.
Its timings are invalid (the laptop was owner-loaded and partly on battery). Only its census
counts stand, labelled "M3 Pro, owner-loaded".

## Findings

- P2 is the win for FAHBench dhfr: single goes from 128.7 to 147.1 ns/day (+14%), mixed from 98.6
  to 118.5 (+20%) (medians of 3 rounds, ranges 0.5 to 2.8). Metal mixed moves from 1.03x to 1.23x
  OpenCL single (96.1). nav and dhfr-implicit have no CCMA, and P2 leaves them unchanged within
  ±1%.
- P3 is the win for mixed precision without CCMA. nav mixed goes from 36.5 to 40.3 (+10%, ranges
  0.1 and 0.3) and dhfr-implicit mixed from 461.2 to 471.9 (+2%). On dhfr, p2p3 mixed is 121.2 vs
  p2's 118.5. Single precision doesn't change anywhere: nav 44.9 vs 45.2, and dhfr-implicit is
  within its noise.
- The kernel census shows why. With P3, computeNonbonded's GPU time in mixed falls to the single
  level: dhfr 148.2 to 111.2 us/step (single 110.6), nav 1657.4 to 1223.1 (single 1190.1). In single
  it doesn't move (110.6 vs 110.8, 1190.1 vs 1189.3). Force-only steps were paying for a df64
  energy sum nobody read. That was 53% of nav's mixed-minus-single GPU time.
- p2p3 is the best Metal build on every work unit and precision. Against OpenCL single (median
  ratios):

  | WU | Metal single p2p3 | Metal mixed base | Metal mixed p2p3 |
  |---|---|---|---|
  | dhfr (CCMA) | 1.54 | 1.03 | 1.26 |
  | nav | 1.01 | 0.82 | 0.90 |
  | dhfr-implicit | 1.04 | 0.79 | 0.81 |

- CCMA explains the FAHBench dhfr lead over OpenCL. In the A/B (3 interleaved rounds, single):
  - dhfr as shipped: Metal 128.4, OpenCL 99.5 (1.29x).
  - dhfr-hbonds, where `hbonds.py` turns the 1,302 heavy-atom constraints into bonds and 22,839
    constraints remain: Metal 220.7, OpenCL 215.3 (1.025x).

  Take CCMA away and the two platforms tie, as on benchmark.py (exp 018). OpenCL loses more to
  CCMA than Metal does. P2 widens the gap to 1.55x (154.4 vs 99.5) and changes nothing on
  dhfr-hbonds (220.5).
- Correctness:
  - Positions, velocities and forces after 1000 steps are bit-identical for base, p2, p3 and p2p3,
    in single and mixed, on dhfr and nav, in 2 repeats each (SHA-256 in `summary.md`).
  - Metal ctest (55 tests per precision) on p2 and p3 fails only TestLocalEnergyMinimizer:229, the
    testLargeForces case of #5434, in both precisions. p2 mixed also failed the stochastic
    MonteCarloFlexibleBarostat once, and it passed on rerun.
- Energies are not bitwise reproducible across contexts, even for one build. Within a context, 50
  evaluations of the start state all return one value. Across contexts:
  - Single precision moves by about one float ulp: dhfr spread 0.035 kJ/mol at 337,089, nav 0.11 at
    1,720,827.
  - Mixed agrees to 1e-9 (dhfr) and 7e-9 kJ/mol (nav).

  Every variant falls inside base's own spread, so the energy criterion that holds is "within
  base's cross-context spread", not "bitwise". Forces use fixed-point accumulation and are
  bit-identical. The energy is a float sum whose order presumably follows the neighbor-list tile
  order. That cause is unverified.
- Where dhfr's time goes (M3 Ultra census, single):
  - Base: 1357 us/step. The GPU is busy 54% of the time and 624 us/step are gaps.
  - Two CCMA sites cause 605 us of those gaps. There are 2.3 finish() drains per step, costing
    909 us of blocked host time, and 9.1 CCMA iterations per call.
  - P2 cuts the drains to 0.04 per step and the gaps to 416 us. It raises busy to 65% and the
    dispatched CCMA iterations to 14.5 per call, because the extra block after convergence
    early-returns.
  - What's left: the host still wakes too late. 211 us/step idle before integrateVerletPart2 after
    the last block, and 190 us between blocks in single, where a block of 4 iterations is shorter
    than the host's wake latency. In mixed the between-block gap is only 27 us, since its
    iterations take 2x longer.
- The M3 Ultra doesn't beat the M3 Pro on dhfr: 1357 vs 1328 us/step in the census runs, and the laptop number is
  only indicative. The FAHBench dhfr step is bound by host round trips, not GPU throughput. nav,
  which is GPU-bound (97% busy), runs 3845 us/step on the Ultra against 8319 on the laptop.
- P3 alone looked 3% slower than base on dhfr single (124.9 vs 128.7) and 1.4% slower in mixed
  (97.2 vs 98.6), with overlapping ranges in mixed. It didn't reproduce. A dedicated rerun (3
  interleaved rounds of 30 s, `p3diag`) gave base 121.0, p3 121.9, base-prof 121.9 and p3-prof
  122.2. The census of the p3 and base profiler builds is the same within noise: GPU busy 747-748
  vs 742-747 us/step, 2.34 finish() per step and 9.1 iterations per call in both. The guard adds
  no branch and no buffer read; in single it only makes the energy sum dead code. Note that
  base itself read 128.7 in step 4 and 121.0 an hour later. dhfr single's wall clock tracks host
  wake latency, which drifts by about 6% between sessions on a shared machine. Compare only
  numbers from the same interleaved block.

## Learnings

- OpenMM's `wrappers/python/setup.py` imports openmm and simtk from the interpreter it runs under
  and deletes those installs (`uninstall()` / `removePackage`), even for a plain `setup.py build`.
  My first `build.sh` built the module with the shared env's Python, and the base build at 16:06Z
  deleted the env's openmm, simtk/openmm and simtk/unit. The lead restored it. I missed it at the
  time: I grepped the log for "site-packages" and read past the three "REMOVING" lines. Rule:
  build OpenMM's Python module with an interpreter that cannot import openmm. `build.sh` now takes
  a separate `<build-python>` (a venv with numpy, Cython and setuptools pinned to the env's
  versions), refuses one that can import openmm or simtk, and fails if `pythonbuild.log` contains
  REMOVING. A rebuild of base with the venv (`blocks-fixcheck.txt`) logged no REMOVING, and the
  shared env still imported its own openmm afterwards.
- An energy bitwise check needs a yardstick first. Base run against base already differs in single,
  so a digest over energies flags every variant. Measure the within-context and cross-context
  spread (`energy.py`) before calling an energy difference a regression.
- `pgrep -f <pattern>` inside `sh -c "..."` sees the wrapper's own command line, and a waiter I
  thought had failed to start was alive in ps under a different name. It started a duplicate chain.
  The lease kept the duplicate strictly serial, so nothing ran at the same time. Wait on a PID
  (`queue.sh`) instead of a pattern.
- Detach remote jobs with `detach.py` (setsid) through `chain.sh` and `leased.sh`, with one
  lease per block of at most ~12 min and a pause between blocks. Over five hours the Studio lease
  passed between lanes without a collision. A 60 s run of nine configurations on nav fits in 11.7
  min.
- A kernel that is faster in the kernel census can be invisible end to end when the step is bound
  by host round trips. P3 cuts 37 us of GPU time per dhfr mixed step and gains nothing without P2,
  because the GPU sits idle 627 us per step anyway. Fix the syncs first, then the kernels.

## Follow-ups

- P2 leaves about 400 us/step of host wake gaps on dhfr single. A deeper pipeline (three blocks in
  flight, the untested `metal-perf-probe-wake` a03975868) or submitting the post-CCMA kernels
  before the last convergence check should close most of it.
- Mixed still trails OpenCL single on nav (0.90) and dhfr-implicit (0.81). The next mixed costs in
  the census are SETTLE and SHAKE (4 to 7x single), the Langevin integrator kernels (2 to 3x) and
  computeKineticEnergy on nav (2.8x).
- Upstream candidates: P3 is a platform-independent guard, so check whether the common
  nonbonded kernel has the same unguarded accumulation. P2 is Metal-only.

## Files

- `build.sh <src> <variant-dir> <python> <build-python>`: one variant, installed into its own
  prefix, plus a `python.sh` wrapper.
- `run.sh <phase> ...`: phases ctest, bits, energy, p1 and runs. Each call is one lease block.
- `leased.sh`, `chain.sh`, `queue.sh`, `detach.py`: lease, block sequencing and detaching on the
  Studio.
- `blocks-*.txt`: the exact blocks that ran, in order: build, verify, p1, time, ab, fixcheck,
  p3diag.
- `profrun.py` (one timed run plus profile line), `bitwise.py` (1000-step digests), `energy.py`
  (energy spread), `hbonds.py` (dhfr with heavy-atom constraints as bonds), `summarize.py`
  (tables).

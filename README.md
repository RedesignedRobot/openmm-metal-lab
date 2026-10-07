# OpenMM Metal lab

Measurements and experiments behind a native Metal platform for OpenMM on Apple GPUs, with Folding@home as the goal.

The platform code is on branch [`pub/metal-platform`](https://github.com/RedesignedRobot/openmm/tree/pub/metal-platform) of the fork RedesignedRobot/openmm. This repository holds the evidence: benchmark runs, kernel studies, correctness checks and the scripts that produced them.

Upstream status: [openmm#5488](https://github.com/openmm/openmm/pull/5488) is the OpenMM team's own Metal platform, and this work feeds data and fixes into it. Two fixes from here are merged upstream ([openmm#5435](https://github.com/openmm/openmm/pull/5435) and [#5436](https://github.com/openmm/openmm/pull/5436)), and [openmm#5397](https://github.com/openmm/openmm/issues/5397) is the discussion thread.

## Results

Every number is OpenMM's own `examples/benchmarks/benchmark.py`, timed with its host wall clock, as the median of interleaved rounds. OpenCL is Apple's OpenCL platform in single precision.

| Chip | Metal build | Method | Metal single / OpenCL | Metal mixed / OpenCL | Raw data |
| --- | --- | --- | --- | --- | --- |
| M3 Ultra, 60-core GPU | 7484d7bef, OpenCL from 6df2b8bcb | 3 rounds of 30 s, 2026-09-25 | 1.401x (gbsa) to 1.894x (apoa1ljpme) | 1.087x (gbsa) to 1.719x (apoa1ljpme) | `experiments/028-ultra-max/windows/w2/summary.txt` |
| M2, 10-core GPU, 8 GB | 5071882fa, both platforms | 3 rounds of 30 s, 2026-09-29 | 1.301x (gbsa) to 1.509x (apoa1rf) | 1.215x (rf, amber20-dhfr) to 1.353x (apoa1rf) | `experiments/029-2x-moonshots/lanes/results/r3-fah-m2-table/summary.txt`, medians only, written by `experiments/029-2x-moonshots/fah/prof/m2table.sh`; the per-round output was not kept |

The measured builds are commits from my private history, so these hashes don't resolve on GitHub. `pub/metal-platform` is a later squash of the same work with the experiment switches removed. The exact commit, source hash and toolchain of each M3 Ultra build are in `experiments/028-ultra-max/windows/w2/ab/configs.txt`.

The GPU was dedicated to the window, but the CPU was not: a background VM used 4% to 162% CPU before the runs (`experiments/028-ultra-max/windows/w2/summary.txt`). gbsa and rf are host-bound, so their M3 Ultra ratios carry that noise.

Both rows cover the nine standard tests: gbsa, rf, pme, apoa1rf, apoa1pme, apoa1ljpme, amber20-dhfr, amber20-cellulose and amber20-stmv. On the M3 Ultra, Metal mixed runs pme 17.5x faster than the CPU platform (780.29 against 44.58 ns/day, `experiments/028-ultra-max/windows/w2/cpu-summary.txt`).

The tables in older experiments sometimes use GPU timestamps instead of the host clock: 009, 010, 011 and 015 do. Don't compare numbers across the two clocks.

## Experiments

Each `experiments/NNN-name/` directory holds one question, its method, its raw results and its scripts. "History" marks work whose conclusions were later corrected or replaced. Read the linked note before you reuse a number from one of those.

| | Question |
| --- | --- |
| 001 | Baseline: OpenCL and CPU platforms on a base M2 |
| 002 | How much of OpenMM's Common kernel source compiles as MSL behind a macro prelude |
| 003 | Where the OpenCL platform spends GPU time on the M2 |
| 004 | Small MSL probes that test claims on both chips |
| 005 | Do the real ApoA1 programs build as Metal (26 of 26) |
| 006 | Numerical agreement, Metal against Apple's OpenCL. History: the erfc paragraph is corrected in `REVIEW-NOTE.md` |
| 007 | Toolchain matrix: MSL versions, math modes, compile time, caching |
| 008 | Host-side cost of dispatch and synchronisation. History: the note misstates the hardware |
| 009 | Neighbour list with SIMD ballot |
| 010, 010b, 010c | computeNonbonded speed and the M2 gap. History: 010's M2 comparison is stale |
| 011 | PME pipeline and FFT choices. History: the tables mix clocks and the note misstates the hardware; `REVIEW-NOTE.md` has the like-for-like numbers |
| 012 | Sort and utility kernels. History: the note misstates the hardware |
| 013 | Does another contributor's Metal branch build and pass OpenMM's tests |
| 014 | Folding@home work unit baseline on the M2 |
| 015 | Mixed precision without fp64 hardware: df64 on the M2 |
| 016 | The native platform, milestone A (`NOTES.md`). History: the test counts are stale |
| 017 | The platform on M2, M3 Pro and M3 Ultra: benchmarks, work units, NVE drift, scaling |
| 018 | `benchmark.py` on all three chips |
| 019 | SIMD-group findBlocksWithInteractions in the platform |
| 020 | A mock Folding@home core on Metal mixed precision |
| 021 | testLargeForces on M3: float to long conversion wraps |
| 022 | Host syncs and the cost of mixed precision |
| 023 | Teaching fah-client to detect an Apple GPU |
| 024 | Metal as the smallest diff from the HIP platform |
| 025 | The best Metal build against OpenCL, with force gates |
| 026 | Skipped: no experiment has this number |
| 027 | History: a port of the plugins, replaced by the plugin work in 028 |
| 028 | The M3 Ultra optimisation round: `FINAL-REPORT.md`, and `DEAD-ENDS.md` for what didn't work and why |
| 029 | Toward 2x OpenCL, and Folding@home readiness (`README.md`, `fah/GAPS.md`) |

`experiments/PROGRAM.md` is the program checklist (compatibility, performance, accuracy) from 2026-09-23 to 24, kept as history. `research/` has design studies and reading notes, and `docs/metal/` has reference notes on MSL and Apple GPUs.

## Reproduce a benchmark

Build and install OpenMM from the `pub/metal-platform` branch. On an arm64 Mac, `OPENMM_BUILD_METAL_LIB` is on by default. Use a fresh Python environment with no other OpenMM in it, because the Python install step removes any `openmm` it can import.

```sh
git clone -b pub/metal-platform https://github.com/RedesignedRobot/openmm.git
cd openmm && mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$HOME/openmm-metal"
make -j8 install
make PythonInstall
python -c "import openmm as mm; print([mm.Platform.getPlatform(i).getName() for i in range(mm.Platform.getNumPlatforms())])"
```

The last line must list `Metal`. If it doesn't, Python is loading a different OpenMM, or the Mac has no supported GPU. Then, from `examples/benchmarks` in the source tree:

```sh
python benchmark.py --platform Metal --precision single --test pme --seconds 30
python benchmark.py --platform OpenCL --precision single --test pme --seconds 30
```

Run each pair several times, alternate the order, and compare medians. Close other GPU work first.

The scripts in `experiments/028-ultra-max/tools/` automate this. `ab.sh` interleaves rounds across any number of builds, each run in a fresh process, and logs machine load before every run. `summarize.py` prints medians, spreads and ratios. `window.sh` runs a full window of every test. `experiments/028-ultra-max/windows/w2.sh` is the exact script behind the M3 Ultra row above, and `windows/w2/ab/configs.txt` records each build's commit, source hash and toolchain. See `experiments/028-ultra-max/tools/README.md`, and `experiments/029-2x-moonshots/tools/README.md` for the later versions.

## Hardware

Mac mini with M2: 8 CPU cores, 10 GPU cores, 8 GB. MacBook Pro with M3 Pro: 12 CPU cores, 18 GPU cores, 36 GB. Mac Studio with M3 Ultra: 60 GPU cores, 96 GB. All on macOS 27.

## License

MIT, see `LICENSE`. Files copied, translated or patched from OpenMM (MIT and LGPL), cbang (LGPL) or fah-client-bastet (GPL) keep their upstream licences wherever they sit in this tree. That covers the `.patch` files, the kernel dumps and the copied sources. The platform branch vendors VkFFT (MIT) and metal-cpp (Apache 2.0) with their notices.

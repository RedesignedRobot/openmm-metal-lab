# Lane: workloads (measure the 2x candidates, no OpenMM code changes)

Brief: measure the candidates in research/2026-09-24-metal-2x-workloads.md on the M3 Ultra against what a Mac user can run today. All runs use ultra-base (6df2b8bcb, venv python). Studio scratch dir /tmp/openmm-metal-bench/ultra-workloads/.

## Tools (in the scratch dir, copies in the laptop scratchpad)

- wl-ab.sh: ab.sh's loop plus the RULES.md checks. Before each (round, test) it waits until `pgrep -x` finds no clang, clang++, ninja or cc1plus, logs the load and `ps -axo pcpu,nice,command -r | head -6` to top.txt, then runs ultra-tools/ab-test.sh under lease.sh. Order reversed every other round.
- workloads.py: probes for items 3 to 5 (sync, ctx, min), host clock `time.perf_counter()`.
- wl-run.sh and wl-round.sh: run workloads.py argument sets for N rounds, one lease.sh hold per round (changed from per run at 20:55Z to cut lease waits), order reversed on even rounds, same build wait and top logging (`<out>.top`).
- sampler.sh: every 20 s while this lane holds the lease, logs load, owner, top 6 processes and any build to psamples.txt. wl-ab.sh's top.txt is taken before the lease wait, so psamples.txt is the one that shows what ran beside a timing.
- chain.sh: items 3, 4, 5 in order after item 1.

## Log

- 19:51Z item 1 launched: `wl-ab.sh mixed-vs-cpu 3 30 pme,apoa1pme,amber20-dhfr,amber20-cellulose` with mmixed (Metal mixed), cpu (CPU platform, benchmark.py forces mixed) and msingle (Metal single). CPU platform Threads default is 28. First launch killed while it waited for the lease (pgrep regex bug on clang++), relaunched 19:53Z; no run had started.
- 20:10Z to 20:55Z: only one lease hold (round 1 pme) in 60 minutes; plugins and profiler ab runs and a gate ctest held it. Told the lead.
- 21:55Z second hold: round 1 apoa1pme. 21:58Z OpenCL refusal captured. Items 3 to 5 (chain.sh) wait for item 1 to finish.
- 19:55Z item 2 measured (a device query, no GPU work). One 10-line C file compiled on the Studio with xcrun clang for about a second; no timing of mine overlapped it.

## Results

### Item 2: allocation caps (M3 Ultra, 96 GiB)

| Query | Value |
|---|---|
| OpenCL CL_DEVICE_MAX_MEM_ALLOC_SIZE | 15655157760 (14.58 GiB) |
| OpenCL CL_DEVICE_GLOBAL_MEM_SIZE | 83494174720 (77.76 GiB) |
| Metal maxBufferLength | 62620631040 (58.32 GiB) |
| Metal recommendedMaxWorkingSetSize | 83494174720 (77.76 GiB) |

The OpenCL cap is exactly maxBufferLength/4. Both share the 77.76 GiB working set. At research's estimate of about 120 bytes per atom for the largest per-atom buffer (interactingAtoms), 14.58 GiB is about 130M atoms, beyond what 77.76 GiB holds on either platform. Dead as a 2x candidate. Sources: limits.c, limits.swift.

### Item 1: Metal against the CPU platform (partial: round 1 of 3, pme and apoa1pme only)

ns/day, host clock (benchmark.py, datetime.now() around step()), ultra-base, 30 s, nice 0. CPU platform: 28 threads (default Threads), benchmark.py forces its precision to mixed.

| Test | CPU | Metal mixed | Metal single | mixed/CPU | single/CPU |
|---|---|---|---|---|---|
| pme | 42.99 | 401.41 | 542.46 | 9.34 | 12.6 |
| apoa1pme | 10.24 | 168.15 | 195.21 | 16.4 | 19.1 |

- CPU pme ran at about 1775% CPU (psamples.txt), beside a 1-core summarize.py from the profiler lane.
- CPU apoa1pme shared the machine with another agent's tsgolint at 393% (ab-test.sh's top log), so it may read up to ~15% low. Not a confirmed number.
- OpenCL refusal, same text for Precision=mixed and double: `OpenMMException 'No compatible OpenCL platform is available'`. `benchmark.py --platform OpenCL --precision mixed --test pme` prints the header, no row, and exits 0 (refusal.out).

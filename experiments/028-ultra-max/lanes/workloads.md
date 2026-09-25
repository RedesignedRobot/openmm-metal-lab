# Lane: workloads (measure the 2x candidates, no OpenMM code changes)

Brief: measure the candidates in research/2026-09-24-metal-2x-workloads.md on the M3 Ultra against what a Mac user can run today. All runs use ultra-base (6df2b8bcb, venv python). Studio scratch dir /tmp/openmm-metal-bench/ultra-workloads/.

## Tools

Sources: experiments/028-ultra-max/workloads/ in the lab (copied 23:00Z, sha256 checked against the Studio copies). They run from /tmp/openmm-metal-bench/ultra-workloads/ on the Studio. wl-ab.sh and chain.sh are retired and kept for the record.

- workloads.py: probes for items 3 to 5 (sync, ctx, min), host clock `time.perf_counter()`.
- wl-run.sh and wl-round.sh: run workloads.py argument sets for N rounds, one nested lease.sh call per round, order reversed on even rounds; each run logs load and VM CPU to `<out>.top`. The whole call is wrapped in one lease.sh ticket. No build wait.
- agg.py: aggregate throughput. `prep` serializes benchmark.py's gbsa and rf systems (outside any hold). `all <dir> 10` runs 1, 2, 4 and 8 concurrent processes per config. Every process builds its Context and warms up, writes a ready file, and waits for a go file the driver writes only once all N are ready; the go file holds a shared wall-clock start and end 10 s apart. Each process runs chunks of ~0.05 s (solo speed) with a getState(energy) sync after each, and logs its actual start, end and every chunk's finish time. Reported: total_ns_day (sum over each process's own window), common_ns_day (sum of rates counted only over chunks inside the interval where all N ran), overlap (that interval over the whole span), per-process start and end offsets, the children's CPU%, the VM's CPU% and the top 5 mid-window. Reference smoke at N=3: starts within 1 ms, overlap 0.995. Updated 23:05Z, before ticket 26490 was granted.
- sampler.sh: every 20 s while this lane holds the lease, logs load, owner, VM CPU, top 6 processes and any build to psamples.txt, so the CPU platform's own %CPU shows during its runs. Stop it with `touch /tmp/openmm-metal-bench/ultra-workloads/sampler.stop`.
- abw.py (prototype, for the lead's decision): ab.sh with one warm process per (configuration, test). Same arguments, refusals, estimate and lease self-wrap as ab.sh. A pre-phase starts every worker in parallel; each loads benchmark.py's functions through ast (its main code runs on import), builds the system with retrieveTestSystem and makes the integrator and Context as runOneTest does (minimizes for amber20), then blocks in a read. Runs go in ab.sh's order, one at a time; each resets the post-setup positions, draws new velocities, runs benchmark.py's own adaptive loop and timeIntegration, and writes the result with benchmark.py's appendTestResult, so summarize.py reads the outdir as is. `--cold <labels>` runs those labels through tools/ab-test.sh, interleaved (the A/A). Logs: loads.txt in ab-test.sh's format, memory.txt (resident, physical footprint, peak per worker, at ready and after each run), runs.txt (wall per run), workers.txt (driver and worker pids). `--validate` skips the lease for Reference and 1 or 2 thread CPU configurations only. The lead asked for a go file per round; I used a line on the worker's stdin, so idle workers block in read() with no polling wakeups during another arm's timing.
- wl-ab.sh (retired 22:52Z): ab.sh's loop plus a build wait before each (round, test), one ticket per (round, test). Its top.txt was taken before the lease wait. Replaced by ultra-tools/ab.sh wrapped in one lease.sh.

## My Studio processes (stop only by these pids, RULES line 57)

| pid | What |
|---|---|
| 46003 | lease.sh ticket: item 1 round 1 amber20-dhfr (parent wl-ab.sh is dead). Done 23:25Z |
| 26490 | lease.sh ticket: aggregate throughput (agg1) |
| 26792 | lease.sh ticket: item 1 round 1 amber20-cellulose (item1-cell) |
| 27230 | lease.sh ticket: item 3 sync |
| 27542 | lease.sh ticket: item 4 ctx |
| 27861 | lease.sh ticket: item 5 min200 |
| 28247 | lease.sh ticket: item 5 minconv |
| 26488 | sampler.sh (stop with `touch /tmp/openmm-metal-bench/ultra-workloads/sampler.stop`, no kill needed) |

## Log

- 19:51Z item 1 launched: `wl-ab.sh mixed-vs-cpu 3 30 pme,apoa1pme,amber20-dhfr,amber20-cellulose` with mmixed (Metal mixed), cpu (CPU platform, benchmark.py forces mixed) and msingle (Metal single). CPU platform Threads default is 28. First launch killed while it waited for the lease (pgrep regex bug on clang++), relaunched 19:53Z; no run had started.
- 20:10Z to 20:55Z: only one lease hold (round 1 pme) in 60 minutes; plugins and profiler ab runs and a gate ctest held it. Told the lead.
- 21:55Z second hold: round 1 apoa1pme. 21:58Z OpenCL refusal captured. Items 3 to 5 (chain.sh) wait for item 1 to finish.
- 22:50Z the 3 h cap was lifted (program has no end time). Lead: kill the unwrapped wl-ab.sh, whose every (round, test) went to the back of a 35-deep queue, and requeue each job as one wrapped lease.sh ticket.
- 22:52Z killed wl-ab.sh 3012, chain.sh 7013 and the old sampler. Kept lease.sh 46003 (queue position 10): with its parent dead it is one hold that runs item 1 round 1 amber20-dhfr through ab-test.sh and ends.
- 22:53Z dropped the build waits from wl-run.sh (lease.sh no longer waits for builds, and a wait inside a hold idles the GPU). New sampler.sh (stops on sampler.stop) logs the VM's CPU too.
- 22:55Z queued six wrapped tickets, positions 49 to 54: agg1 (aggregate throughput), item1-cell (ab.sh, round 1 cellulose), sync.jsonl, ctx.jsonl (3 rounds), min200.jsonl, minconv.jsonl (2 rounds).
- 23:10Z infra's ab.sh now logs, for every CPU run, the platform's default thread count and every 5 s the benchmark's %CPU, the busiest other process and the VM, and marks CPU BUSY beside any process over 100%. The per-run sampling lives in ab-test.sh, which both item1-cell (through ab.sh) and ticket 46003 call when their holds start, so both get it.
- ultra-base was rebuilt with the Xcode-beta SDK 20:35 to 20:37Z. Round 1 pme (20:10Z) ran on the Command Line Tools build and stands as a screen; round 1 apoa1pme (21:55Z) ran on the beta build.
- 23:25Z ticket 46003 done: item 1 round 1 amber20-dhfr (table below). The CPU run shared the machine with xctrace at 285% (CPU BUSY) and the msingle run overlapped a build.
- 23:30Z to 23:58Z abw.py built and checked with no GPU ticket: Reference and 2-thread CPU arms, warm and cold interleaved (abwv1, abwv2), refusals and the lease re-exec against a private fake lease.sh (abwtest/), a worker that fails setup, a worker killed by its recorded pid while idle. An adversarial review (fresh context) found 8 issues; I fixed the 7 inside abw.py. The 8th is in ab-test.sh (below).
- 23:37Z my failure test ran amoebagk on the 2-thread CPU platform, which is slow, not failing. I stopped the driver 36530 and worker 36741 (worker pid from workers.txt, driver its parent). The driver had just started a cold ab-test.sh that outlived it; I stopped that run by its pids 68315, 68338, 68364 and 68365, all in my own ssh command's process group. Nothing else was touched.
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

### Item 1: Metal against the CPU platform (partial: round 1 of 3, pme, apoa1pme and amber20-dhfr)

ns/day, host clock (benchmark.py, datetime.now() around step()), ultra-base, 30 s, nice 0. CPU platform: 28 threads (default Threads), benchmark.py forces its precision to mixed.

| Test | CPU | Metal mixed | Metal single | mixed/CPU | single/CPU |
|---|---|---|---|---|---|
| pme | 42.99 | 401.41 | 542.46 | 9.34 | 12.6 |
| apoa1pme | 10.24 | 168.15 | 195.21 | 16.4 | 19.1 |
| amber20-dhfr | 50.76 | 410.39 | 557.52 | 8.08 | 11.0 |

- CPU pme ran at about 1775% CPU (psamples.txt), beside a 1-core summarize.py from the profiler lane.
- CPU apoa1pme shared the machine with another agent's tsgolint at 393% (ab-test.sh's top log), so it may read up to ~15% low. Not a confirmed number.
- CPU amber20-dhfr ran beside xctrace at 285% (benchmark 1459% to 1663% over 6 samples, CPU BUSY), so the CPU number is low and both dhfr ratios high. Metal single dhfr overlapped a build (BUILD RUNNING).
- OpenCL refusal, same text for Precision=mixed and double: `OpenMMException 'No compatible OpenCL platform is available'`. `benchmark.py --platform OpenCL --precision mixed --test pme` prints the header, no row, and exits 0 (refusal.out).

### abw.py: what a warm process saves

Cold per-run overhead, measured: wall between consecutive run starts in loads.txt minus the timed elapsed_time, over 16 ab.sh screens of every lane on the M3 Ultra (overhead.py, 1 s timestamps). It includes benchmark.py's calibration (20 steps, then about 1 s of steps, then 5 steps), which a warm run also pays.

| Test | Platform | Precision | Runs | Median s | p25 to p75 |
|---|---|---|---|---|---|
| gbsa | Metal | single | 16 | 1.3 | 1.1 to 2.0 |
| rf | Metal | single | 12 | 1.8 | 1.1 to 1.9 |
| pme | Metal | single | 12 | 1.9 | 1.0 to 2.0 |
| gbsa | Metal | mixed | 23 | 3.9 | 1.0 to 5.0 |
| rf | Metal | mixed | 18 | 3.0 | 1.9 to 4.3 |
| pme | Metal | mixed | 21 | 3.9 | 2.0 to 5.0 |
| apoa1pme | Metal | single | 11 | 3.9 | 2.9 to 4.0 |
| amoebagk | Metal | mixed | 9 | 10.1 | 9.3 to 14.7 |
| amoebapme | Metal | mixed | 6 | 17.4 | 15.3 to 19.4 |

ab.sh's setup table says 4 s for gbsa, rf and pme; single-precision runs measure 1.3 to 1.9 s. Item 1's 30 s runs: amber20-dhfr Metal mixed 5 s, pme mixed 2.2 s, apoa1pme mixed 3.8 s.

Validation, Reference and 2-thread CPU, 5 s runs, 2 rounds, warm and cold interleaved (abwv1): warm/cold 0.979 (gbsa) and 1.034 (rf) on Reference, 1.009 and 1.034 on CPU, all inside the rounds' own spread (0.3% to 7.4%; xctrace ran at 170% to 780% throughout). Wall per run, warm against cold: gbsa 3.6 and 4.0 s against 4.0 and 4.1 s on Reference, rf 6.0 s against 6.8 and 7.1 s on CPU. Worker memory after round 2: 92 MB (gbsa) to 254 MB (rf) resident, 66 to 190 MB footprint. Reference and CPU only; Metal footprints come with the A/A ticket.

## What's next

- abw.py proposal sent to the lead; the A/A ticket waits for the lead's decision.
- ab-test.sh gap for infra (not mine to change): benchmark.py writes the system block to --outfile before it runs anything, so a run that dies later (swallowed OpenMMException, perl alarm, crash) leaves a non-empty file with an empty benchmarks list. `[ -s "$result" ]` passes, no NO RESULT is logged, and summarize.py drops the round without a word. The check should look for a non-empty benchmarks list.
- Wait for the six tickets. Summaries: `summarize.py mixed-vs-cpu mmixed/cpu msingle/cpu`, `summarize.py item1-cell mmixed/cpu msingle/cpu`, `wlsum.py <file>.jsonl` for sync, ctx, min200 and minconv, and agg1/agg.jsonl for aggregate throughput.
- Item 1 rounds 2 and 3 and the clean CPU baseline go in the first dedicated window (spec sent to infra for window.sh).
- Item 4 "unique" adds 1 to 5000 zero-charge, zero-epsilon ghost atoms so NUM_ATOMS changes and neither platform's compiled-kernel cache can hit; "proc" is a fresh process on the unchanged system; "second" in each row is a second Context in the same process.
- Item 5 times LocalEnergyMinimizer.minimize(tolerance 10) on apoa1pme with maxIterations 200 and 0 (converge), no reporter, so no per-iteration downloads skew it.

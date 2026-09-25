# Profiler lane

Goal: where the time goes per MD step on the M3 Ultra for 6df2b8bcb, so the other lanes aim at the right kernels.

## State

- Worktree /Users/amir/code/mini/ultra-profiler, branch ultra/profiler at 6df2b8bcb plus uncommitted lab-only probes (7 files, 24 lines added and 7 removed, plus the new GpuProf.h). Not for upstream. The same diff is `profiler/gpuprof.patch`, regenerated at 21:54Z: it applies on a clean 6df2b8bcb and reproduces all 8 files byte for byte, so other lanes can add the probes to their own tree.
- Studio dir /tmp/openmm-metal-bench/ultra-profiler: src, prefix, venv, tools (copies of experiments/028-ultra-max/profiler), results in p1/ (single), p2/ (mixed, dhfr single, split), stmv/, probes/, xtrace/, sweep/. The build dir is src/build-xb, built with Xcode-beta 27.2 (libOpenMMMetal LC_BUILD_VERSION sdk 27.2), last rebuilt at 21:52Z with the gated pipeline labels (Method). src/build is the old Command Line Tools build and is no longer used.
- Started 19:22Z. No cap: the owner dropped the freeze at 21:58Z and the program runs continuously. My order from the lead (21:56Z): the tbpc24 grid-cap result, then a per-kernel census with repeats of every candidate that passes the gate and of ultra/integrated, then the xctrace export schema.
- Queued under lease.sh (queue about 60 deep, about 6 hours): 1e, the GBSA kill test (30130), which decides roadmap 5, and the shader-timeline hold (74311, queued 23:52Z at the back: gbsa check, then apoa1rf on ultra-base and words 4be61f9b6; Xcode Metal System Trace). Done: stmv rounds 1 and 2 (round 3 stopped), probes, xctrace. Dropped: both grid-cap sweeps (stopped by pid at 23:23Z) and the tbpc24 census (91086, stopped by pid at 23:30Z, since a per-kernel view of a knob that is dead end to end decides nothing).
- 1e (computeGBSAForce1 kill test, research's patches in experiments/028-ultra-max/patches/gbsa-kill/): built at 22:09Z and queued as ticket 30130 (29th). Arms: base, kill (gbsa-kill.patch: one fast rsqrt per pair and a per-atom 1/B) and rsqrt (gbsa-kill-rsqrt-only.patch, research's arm B for a borderline result). Both patches failed one hunk on my tree, only because gpuprof adds `#include "GpuProf.h"` where they add `#include "CommonKernelSources.h"`; `profiler/1e-kill-probe.patch` and `1e-rsqrt-probe.patch` are the rebased versions, with changed lines identical to research's. Each plugin embeds its own variant (checked with strings). `profiler/1e.sh` runs, in one hold, forces.py's own code narrowed to gbsa (checked against infra's 22:13Z argparse version, which computes Reference itself here because my benchmarks dir has no cached reference; single and mixed, against ultra-base/forces.txt, the Xcode-beta baseline, also the swap check: identical digits to base mean the swap didn't take), then `census.sh census/1e single gbsa 3 base kill rsqrt`. Decision rule: computeGBSAForce1 down 10% or more (about 5 us of 51.5) continues Stage A, under 5% narrows GBSA to the launch shape. Result to the lead and nonbonded. Between the forces and the census, the same hold runs the end-to-end timing the lead asked for at 22:30Z: `profiler/gbsakill.sh` into census/1e/ab, ab.sh on gbsa single and mixed, 2 interleaved rounds of 15 s, arms prof (the profiling tree both kill builds come from), kill and rsqrt: 12 runs. The whole hold is 8 to 17 minutes (gbsa runs took 16 s apart in mixed's screenG2; the lead budgets 1 minute), under the 20 minute cap. kill against prof is the patch alone; prof against ultra-base, the probe tree's own offset, comes from the probes (36210). The patches' added kernels match the lab's gbsaObc.metal and gbsaObc-rsqrt-only.metal byte for byte, and each arm loads its own libOpenMMMetal.dylib (checked with openmm.pluginLoadedLibNames, no GPU).
- Other lanes can run the profiler on their own build: `PY=<their venv python> /tmp/openmm-metal-bench/ultra-profiler/tools/profile.sh <out> <buffers|counters|split> <single|mixed> <tests> [extra env]` under their own lease.sh.

## Method

`profiler/` holds the tools. The profiling build adds `platforms/metal/src/GpuProf.h` and 20 hook lines. `GPUPROF` picks a mode:

- `buffers`: normal batching; every command buffer records its GPU start and end, host commit time, dispatch and blit counts; host waits record their length.
- `counters`: as buffers, plus one compute encoder per dispatch with stage-boundary timestamp samples (MTLCounterSampleBuffer, the "timestamp" counter set) at the start and end of each encoder.
- `split`: one encoder per dispatch with no samples, to price the split alone.

`prof.py` builds the benchmark.py system and integrator the way runOneTest does, then times three windows of the same step count (about 4 s each): A and C unrecorded, B recorded. B over the mean of A and C is the recording's cost. Step time is the host clock (`time.perf_counter`) around step(n) plus getState(energy), as benchmark.py times it. `summarize.py` turns one run into a per-step line and a kernel table, `aggregate.py` builds the cross-test tables, `levers.py` the category shares and lever estimates.

Clock check: the counter samples, both halves of a `sampleTimestamps` pair and `GPUStartTime` x 1e9 are all nanoseconds on one clock on this OS (first encoder start 109335017158458 against its buffer's GPUStartTime 109335.017158417). The mach timebase (125/3) does not apply.

Kernel times are attributed times. In counters mode Metal runs consecutive encoders concurrently where hazard tracking allows, so the sum of encoder start-to-end times runs 1 to 27% above their union (stmv 17727 against 15199 us/step). `summarize.py` splits every stretch of covered time evenly among the encoders running in it, so the kernel times add up to GPU busy time. `levers.py` then scales them to the buffers-mode (production) GPU busy time. findBlocksWithInteractions overlaps the most: its raw time is about 2x its attributed time on apoa1pme, cellulose and stmv.

Env knobs in the profiling build: `HD_TBPC` (thread blocks per core, default 12), `HD_NB_BLOCKS` (nonbonded blocks per core, default 40), `HD_NB_TG` (nonbonded threadgroup size, default 64).

Labels. With GPUPROF set, getKernel builds every pipeline from a descriptor labeled with its kernel name (`gpuprof::newPipeline`), and split and counters modes label each encoder with its kernel, so gpudebug and Metal System Trace name every row instead of listing anonymous pipelines. Without GPUPROF the pipeline is built exactly as upstream builds it, so runs that set no GPUPROF, like the probes' prof, nb6x256 and tbpc24 arms, time the upstream path plus the inert hooks.

Census. `census.sh <out> <precision> <tests> <repeats> <arm>...` runs prof.py in counters mode for each arm, where an arm is a name plus environment (`base`, `tbpc24:HD_TBPC=24`, `cand:OPENMM_PLUGIN_DIR=<prefix>/lib/plugins`), interleaved per test and repeat with the order reversed on every other repeat. `census.py <out>` summarizes the records after the lease and prints, per test, the unrecorded wall, the kernel union (GPU time covered by any kernel; command buffer busy time is left out because counter sampling inflates it 1.9x on gbsa) and the top kernels' attributed us/step as mean +- SD over repeats, each arm's delta against the first arm, the delta as a share of the kernel and of the wall, and any grid change. A delta is marked when it exceeds 3 standard errors, about Welch's 95% point at 3 repeats per arm. For a candidate, `mkcensus.sh <commit> <patch>` (laptop, no build) writes the patch from the profiling tree to the candidate plus gpuprof.patch, and `build-patch.sh` builds it into its own prefix on the M3 Ultra. It applies cleanly on the pme (17929e631), mixed (6c97bd5de), nblist (411a9f19a) and atomics (9eb009703) heads as of 22:05Z. `xschema.py <trace>` prints an xctrace trace's export schema: every table in the TOC with its columns, engineering types, row count and sample rows.

`gpusweep.sh` runs Apple's GPU tools at several grid caps: per test:tbpc config it starts prof.py with MTL_CAPTURE_ENABLED=1, HD_TBPC and split mode, captures 8 command buffers (4 steps) with `gpucapture` once window A has printed, stops prof.py, and replays the capture with `gpudebug profile run --gpu-state high --exec serial`, listing the shader, command, encoder and counter tables as JSON. It starts no new config after 13 minutes, so a 4-config ticket stays under the 20-minute hold cap.

`segment.py` gives the union, sum and span of the encoders from one kernel to another per step in a counters record (default: LangevinMiddle Part1 through Part3). `gaps.py` splits a buffers record's idle time by position in the step and times the host chain between buffers. `kicks.py <test>-gpu-intervals.xml <test>-single.txt` does the same from a Metal System Trace with no GpuProf.h instrumentation: per prof.py window, GPU busy time (the union of the traced process's kicks), idle, and the gaps between consecutive kicks by size and by the pair of kicks around them.

Load sensitivity. p1 and p2 ran on the shared Studio at a 1-minute load of 5 to 9, with the Hyperscale VM and other lanes' builds in the background. Absolute times (wall, GPU busy, per-kernel us) carry that noise, and so do the mixed/single wall ratios, which compare runs taken 50 minutes apart. What holds regardless of load: kernel shares within one run, buffer, dispatch, blit and wait counts per step, rebuild rates, the ordering of the gap chain, and the counters-mode perturbation pattern (a host-side cost on small systems). p1 and p2 used the Command Line Tools build of the host code. Metal compiles the kernels at run time from source, so the kernel times should not depend on that toolchain, but I have not checked that against the Xcode-beta build.

## Results

### Per step, Metal single, buffers mode

1-minute load 5 to 9. dhfr comes from p2 (the p1 run failed on the NetCDF restart file before scipy was installed).

| Test | Wall us/step | GPU busy | Idle gap | Gap % | Buffers/step | Dispatches/step | Event waits/step | Recorded/unrecorded |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| gbsa | 293.0 | 268.5 | 24.5 | 8.3% | 2.00 | 20.3 | 1.00 | 1.013 |
| rf | 501.7 | 455.8 | 45.9 | 9.1% | 2.00 | 18.3 | 1.00 | 1.020 |
| pme | 639.1 | 632.2 | 6.9 | 1.1% | 2.00 | 27.3 | 1.00 | 1.000 |
| apoa1rf | 1144.5 | 1130.7 | 13.7 | 1.2% | 2.01 | 22.3 | 1.00 | window C noisy |
| apoa1pme | 1772.1 | 1759.8 | 12.4 | 0.7% | 2.01 | 31.3 | 1.00 | 1.001 |
| apoa1ljpme | 2390.6 | 2379.3 | 11.3 | 0.5% | 2.01 | 47.3 | 1.00 | 1.000 |
| amber20-dhfr | 606.3 | 600.2 | 6.2 | 1.0% | 2.00 | 27.3 | 1.00 | 1.000 |
| amber20-cellulose | 6370.6 | 6328.7 | 41.9 | 0.7% | 2.01 | 31.3 | 1.00 | 1.000 |
| amber20-stmv | 16303.7 | 16153.8 | 149.9 | 0.9% | 2.02 | 31.3 | 1.00 | 1.004 |

Finish waits are 0.02 per step everywhere (the getState at each window's end). Blits: 1 per step on gbsa, rf, pme and dhfr, about 0 on the rest. The one event wait per step is where the host sits: 246 of 293 us on gbsa, 453 of 502 on rf, 572 of 639 on pme. Of the idle gap, the host committed after the GPU ran dry for only 1.4 us/step on gbsa and 3.5 on rf; the rest is time between commit and GPU start across the 2 buffers per step (about 12 us per buffer on gbsa, 21 on rf).

### Where the idle gap sits (gaps.py, single, buffers mode)

Each step is buffer X (the integrator's tail from the previous step, force prep through findBlocksWithInteractions, then the interaction-count download blit and the event signal) and buffer Y (computeBondedForces and computeNonbonded on rf, 2 dispatches). The host commits Y right behind X, waits on X's event, encodes the next step and commits X'. Medians in us:

| Quantity | gbsa | rf | pme | dhfr |
|---|---:|---:|---:|---:|
| X GPU time | 66.4 | 359.4 | 323.5 | 142.1 |
| Y GPU time | 179.9 | 178.6 | 357.1 | 382.3 |
| Idle X end to Y start, mean (median) | 13.4 (0.5) | 1.8 (0.5) | 0.7 (0.5) | 0.8 (0.4) |
| Idle Y end to X' start, mean (median) | 9.8 (0.5) | 40.1 (33.4) | 2.0 (0.5) | 1.6 (0.5) |
| Host wake after X's GPU end | 45.4 | 70.8 | 69.3 | 75.6 |
| Host wake to X' commit | 21.2 | 22.7 | 27.8 | 16.7 |
| X' commit to X' scheduled (difference of medians) | 66.3 | 77.7 | 73.1 | 66.7 |
| X' scheduled to X' start (on pme and dhfr, queued behind Y) | 52.1 | 33.9 | 189.8 | 210.2 |
| Worst 1% of steps: share of idle time | 15.0% | 7.8% | 53.2% | 51.3% |

On rf the gap sits after Y. From X's end, the host takes 71 us to wake, 23 to encode, and the command buffer takes 78 from commit to scheduled and 34 more to start: about 205 us against Y's 179, which leaves the 33 us median gap. Encoding is the smallest link, so a faster encoder alone cannot close it; a quicker wake (polling the event instead of waitUntilSignaledValue) or a shorter commit-to-start path can. On gbsa, X is shorter (66 us) than the commit-to-start latency of Y on non-rebuild steps, so the gap moves in front of Y (p90 43 us). pme and dhfr hide the whole chain behind a 357 to 382 us Y. Rf mixed is the same chain with a 58 us mean gap, and X' commits after Y ends on 12.5% of steps.

The gap is spread over ordinary steps, not tied to reorderAtoms. Steps whose X has 9 dispatches come once per about 245 steps (0.41%), which matches the 250-step reorder; they hold 0.2% of gbsa's idle time and 0.7% of rf's, and none is in the worst 1%.

### Per step, Metal mixed, buffers mode

| Test | Wall us/step | GPU busy | Idle gap | Gap % | Buffers/step | Dispatches/step | Event waits/step | Recorded/unrecorded | Mixed/single wall |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| gbsa | 417.8 | 404.8 | 13.0 | 3.1% | 2.00 | 20.3 | 1.00 | 1.006 | 1.43 |
| rf | 743.4 | 680.8 | 62.6 | 8.4% | 2.00 | 18.3 | 1.00 | 0.996 | 1.48 |
| pme | 867.6 | 860.2 | 7.4 | 0.9% | 2.00 | 27.3 | 1.00 | 1.001 | 1.36 |
| apoa1rf | 1426.9 | 1408.5 | 18.4 | 1.3% | 2.01 | 22.3 | 1.00 | 1.007 | 1.24 |
| apoa1pme | 2059.8 | 2045.3 | 14.5 | 0.7% | 2.01 | 31.3 | 1.00 | 1.001 | 1.16 |
| apoa1ljpme | 2667.8 | 2652.9 | 15.0 | 0.6% | 2.01 | 47.3 | 1.00 | 1.003 | 1.12 |
| amber20-dhfr | 836.6 | 829.7 | 6.9 | 0.8% | 2.00 | 27.3 | 1.00 | 1.003 | 1.38 |
| amber20-cellulose | 7052.2 | 6997.2 | 55.1 | 0.8% | 2.01 | 31.3 | 1.00 | 1.000 | 1.11 |
| amber20-stmv | 18049.3 | 17866.0 | 183.3 | 1.0% | 2.02 | 31.4 | 1.00 | 1.006 | 1.10 |

Mixed/single wall is the median of the four unrecorded windows (buffers and counters runs) in each precision. Same buffer, dispatch and wait counts as single.

### What the recording costs

Buffers mode: 1.000 to 1.020 of unrecorded, so the per-step tables are the real step.

Counters mode (recorded over unrecorded):

| Test | Single | Mixed | Split only, single |
|---|---:|---:|---:|
| gbsa | 2.175 | 1.651 | 1.040 |
| rf | 1.733 | 1.409 | 1.027 |
| pme | 1.325 | 1.069 | 0.998 |
| apoa1rf | 1.046 | 1.009 | |
| apoa1pme | 0.960 | 0.951 | 1.003 |
| apoa1ljpme | 1.006 | 1.001 | |
| amber20-dhfr | 1.348 | 1.100 | |
| amber20-cellulose | 0.940 | 0.940 | |
| amber20-stmv | 0.944 | 0.935 | |

The slowdown on small systems is host-side: the counters-mode union of encoder intervals on pme is 600 us/step against 632 us of GPU busy time in buffers mode, while the wall grows 33%. The split alone costs 4.0% on gbsa and 2.7% on rf and nothing on pme and apoa1pme, so most of the counters cost is the sample handling. Counters mode runs 4 to 6.5% faster than unrecorded on apoa1pme, cellulose and stmv, in both precisions, and the split alone does not (apoa1pme 1.003, GPU busy 1776 against 1760 us). So the speedup comes with the sample attachments, not with one encoder per dispatch. My guess is that the driver merges plain consecutive compute encoders and cannot merge ones with sample attachments, so only the latter overlap. I have not tested that.

### Top 5 kernels per test, single

Attributed us/step and share of GPU busy (counters union, first column):

| Test | Busy us | 1 | 2 | 3 | 4 | 5 |
|---|---:|---|---|---|---|---|
| gbsa | 292 | computeNonbonded 2400x64 52.8 (18%) | computeGBSAForce1 720x64 51.5 (18%) | computeBornSum 720x64 44.7 (15%) | computeBondedForces 115x64 26.1 (9%) | findBlocksWithInteractions 78x32 21.4 (7%) |
| rf | 466 | computeNonbonded 149.6 (32%) | findBlocksWithInteractions 737x32 147.4 (32%) | sortShortList2 12x64 47.2 (10%) | computeBondedForces 18.6 (4%) | applySettleToPositions 10.7 (2%) |
| pme | 600 | computeNonbonded 121.1 (20%) | findBlocksWithInteractions 95.7 (16%) | gridSpreadCharge 369x64 90.6 (15%) | sortShortList2 48.3 (8%) | computeBondedForces 40.9 (7%) |
| apoa1rf | 1124 | computeNonbonded 484.4 (43%) | findBlocksWithInteractions 2882x32 272.3 (24%) | computeBondedForces 720x64 141.4 (13%) | generateRandomNumbers 38.7 (3%) | sortBoxData 30.8 (3%) |
| apoa1pme | 1668 | computeNonbonded 412.8 (25%) | gridSpreadCharge 720x64 339.3 (20%) | computeBondedForces 250.4 (15%) | findBlocksWithInteractions 174.8 (10%) | computeRange 1x256 53.1 (3%) |
| apoa1ljpme | 2339 | gridSpreadCharge 620.7 (27%, 2 per step) | computeNonbonded 453.3 (19%) | computeBondedForces 255.9 (11%) | computeRange 211.2 (9%) | findBlocksWithInteractions 157.3 (7%) |
| amber20-dhfr | 585 | computeNonbonded 121.8 (21%) | gridSpreadCharge 99.8 (17%) | findBlocksWithInteractions 67.4 (12%) | sortShortList2 48.4 (8%) | computeBondedForces 40.9 (7%) |
| amber20-cellulose | 5920 | computeNonbonded 1725.5 (29%) | gridSpreadCharge 1522.1 (26%) | computeBondedForces 942.8 (16%) | findBlocksWithInteractions 12770x32 504.4 (9%) | gridInterpolateForce 172.3 (3%) |
| amber20-stmv | 15199 | gridSpreadCharge 4712.2 (31%) | computeNonbonded 4569.2 (30%) | computeBondedForces 1860.9 (12%) | findBlocksWithInteractions 33347x32 1027.5 (7%) | gridInterpolateForce 525.7 (3%) |

Category shares of the unrecorded wall time (levers.py, kernel times scaled to production GPU busy):

| Test | Wall us | Nonbonded | Nlist | Short sort | computeRange | Bucket sort | Spread | FFT, conv, interp | Bonded | GB | Other | Gap |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| gbsa | 290 | 17% | 13% | 3% | 0% | 0% | 0% | 0% | 8% | 35% | 18% | 8% |
| rf | 492 | 30% | 34% | 9% | 0% | 0% | 0% | 0% | 4% | 0% | 16% | 9% |
| pme | 639 | 20% | 19% | 8% | 2% | 3% | 16% | 11% | 7% | 0% | 13% | 1% |
| apoa1rf | 1146 | 43% | 28% | 0% | 1% | 3% | 0% | 0% | 12% | 0% | 11% | 1% |
| apoa1pme | 1774 | 25% | 13% | 0% | 3% | 5% | 23% | 9% | 15% | 0% | 7% | 1% |
| apoa1ljpme | 2384 | 19% | 8% | 0% | 9% | 10% | 28% | 11% | 11% | 0% | 5% | 0% |
| amber20-dhfr | 605 | 21% | 15% | 8% | 3% | 3% | 18% | 11% | 7% | 0% | 14% | 1% |
| amber20-cellulose | 6361 | 29% | 10% | 0% | 3% | 4% | 27% | 7% | 16% | 0% | 4% | 1% |
| amber20-stmv | 16239 | 30% | 8% | 0% | 2% | 5% | 32% | 7% | 12% | 0% | 4% | 1% |

Per-kernel facts behind the shares:

- The neighbor list rebuilds on every second step on the explicit tests (50.2% on rf, pme, apoa1rf, apoa1pme, apoa1ljpme, cellulose and stmv), every third on dhfr (33.7%) and on 8.0% of gbsa's; mixed is the same. Research's CPU replay of the Metal trigger gives the same rates. A rebuild is a findBlocksWithInteractions dispatch above the largest ratio gap in its sorted raw durations; that gap is 8x to 57x on every test (4x on dhfr mixed). The non-rebuild dispatch (the early return) takes 5 to 8 us raw on the dhfr-size tests and 8 to 66 us on the big ones, stretched by overlap. Per rebuild, raw median / overlap-attributed median in us: rf 298/288, pme 270/183, dhfr 270/188, gbsa 212/212, apoa1rf 557/536, apoa1pme 620/323, apoa1ljpme 474/309, cellulose 1613/807, stmv 3999/2000. Raw counts time shared with overlapping encoders and attributed splits it evenly, so the cost to the step sits between the two.
- computeRange runs as 1 threadgroup since 9074c38f1: 121 us per call on apoa1ljpme with 3 calls per step, about 1.25 ms per call on stmv.
- sortShortList2 is an O(n^2) rank sort in 64-thread chunks: 48 us every step for 737 blocks (12x64), 8.6 us for gbsa's 78.
- PME sorts its atoms every other step above 15,000 atoms and every 4th below (CommonCalcNonbondedForce.cpp:981). On stmv one sort is sortBuckets 1.27 ms, assignElementsToBuckets 0.64 ms, copyDataToBuckets 0.43 ms, computeRange 1.25 ms, computeBucketPositions 0.37 ms.
- gridSpreadCharge, computeBondedForces, gridInterpolateForce, the integrator kernels and generateRandomNumbers all run at 720x64 on large systems: MetalContext::executeKernel (MetalContext.cpp:592) clips every grid to numThreadBlocks = 12 per core x 60 cores. On stmv that is 46,080 threads for 1.07M atoms. GBSA hits it too: computeBornSum and computeGBSAForce1 ask for nb.getNumForceThreadBlocks() x 64 threads, 2400 groups (CommonKernels.cpp:2100 and 2102), and get 720. computeNonbonded escapes the cap because MetalNonbondedUtilities launches it through executeKernelFlat (:446), so it runs its full 2400x64. computeBondedForces runs 720x64 on the apoa1 tests, cellulose and stmv, 543x64 on pme and dhfr, 115x64 on gbsa and rf.
- Share of attributed GPU time in dispatches at the 720-group cap (p1 single, counters): gbsa 35.2% (computeGBSAForce1 17.6, computeBornSum 15.3), apoa1rf 21.0%, apoa1pme 48.5%, apoa1ljpme 53.4%, cellulose 52.1%, stmv 53.7%, rf 1.8%, pme 4.1%, dhfr 4.3%. Spread and bonded are most of it on the big systems. The cap only matters where a capped kernel has more work than 720 groups can hide, and the tbpc24 probe and the tbpc sweep test that.
- The interaction tile count (interactionCount[0]) is not recorded; GpuProf.h times dispatches and does not read buffers.

### PME kernels, single (p1, counters mode)

Median per dispatch in us, dispatches per step in brackets, p90 where it differs a lot. VkFFT gets one encoder per transform, so vkFFTforward and vkFFTbackward each cover all of that transform's dispatches.

| Kernel | pme | apoa1pme | apoa1ljpme |
|---|---|---|---|
| findAtomGridIndex | 5.5 (0.5) | 10.0 (0.5) | 7.9 (2) |
| sortBuckets, PME atom sort | 14.1 (0.5) | 30.8 (0.5) | 28.8 (2) |
| assignElementsToBuckets | 11.0 (0.5) | 192.9 (0.5) | 20.0 (2), p90 238.8 |
| computeBucketPositions | 5.6 (0.5) | 7.5 (0.5) | 7.1 (2) |
| copyDataToBuckets | 6.2 (0.5) | 9.2 (0.5) | 9.2 (2) |
| computeRange, 1x256 | 39.3 (0.5) | 18.2 (1.5), p90 123.6 | 121.2 (3) |
| gridSpreadCharge | 114.1 (1) | 425.9 (1) | 313.4 (2), p90 421.8 |
| finishSpreadCharge | 7.9 (1) | 17.8 (1), p90 257.6 | 16.6 (2) |
| vkFFTforward | 22.8 (1) | 57.7 (1) | 43.1 (2) |
| vkFFTbackward | 22.5 (1) | 57.9 (1) | 41.2 (2) |
| reciprocalConvolution | 7.4 (1) | 14.1 (1) | 13.2 (2) |
| gridInterpolateForce | 18.5 (1) | 43.8 (1) | 42.9 (2) |

The apoa1 tests also run a second, smaller sort every step (sortBuckets 90x256, assignElementsToBuckets2 23x128, computeBucketPositions 1x90, copyDataToBuckets 46x64): 10.9 + 15.6 + 5.5 + 5.4 us on apoa1pme, 11.2 + 17.2 + 5.5 + 5.8 on apoa1ljpme. pme runs sortShortList2 (12x64) at 48.5 us every step instead, more than its PME sort costs per step (76 us every other step). Raw medians overlap with neighboring encoders on the big systems, so use the attributed us/step in p1/<test>-single-counters.sum for shares.

### Top 5 kernels per test, mixed

| Test | Busy us | 1 | 2 | 3 | 4 | 5 |
|---|---:|---|---|---|---|---|
| gbsa | 409 | computeGBSAForce1 55.4 (14%) | computeNonbonded 53.1 (13%) | applyShakeToPositions 13x64 52.1 (13%) | computeBornSum 44.2 (11%) | applyShakeToVelocities 43.1 (11%) |
| rf | 665 | computeNonbonded 151.0 (23%) | findBlocksWithInteractions 141.4 (21%) | applySettleToPositions 66.5 (10%) | applyShakeToPositions 51.5 (8%) | applySettleToVelocities 48.3 (7%) |
| pme | 792 | computeNonbonded 120.8 (15%) | findBlocksWithInteractions 92.6 (12%) | gridSpreadCharge 87.3 (11%) | applySettleToPositions 67.2 (8%) | applyShakeToPositions 52.2 (7%) |
| apoa1rf | 1380 | computeNonbonded 485.5 (35%) | findBlocksWithInteractions 272.3 (20%) | computeBondedForces 134.6 (10%) | applySettleToPositions 70.2 (5%) | applyShakeToPositions 56.1 (4%) |
| apoa1pme | 1927 | computeNonbonded 406.6 (21%) | gridSpreadCharge 340.3 (18%) | computeBondedForces 249.2 (13%) | findBlocksWithInteractions 172.6 (9%) | applySettleToPositions 71.6 (4%) |
| apoa1ljpme | 2624 | gridSpreadCharge 622.7 (24%) | computeNonbonded 453.7 (17%) | computeBondedForces 251.9 (10%) | computeRange 211.6 (8%) | findBlocksWithInteractions 158.1 (6%) |
| amber20-dhfr | 787 | computeNonbonded 120.8 (15%) | gridSpreadCharge 94.7 (12%) | applySettleToPositions 67.2 (9%) | findBlocksWithInteractions 65.8 (8%) | applyShakeToPositions 55.4 (7%) |
| amber20-cellulose | 6569 | computeNonbonded 1719.4 (26%) | gridSpreadCharge 1456.3 (22%) | computeBondedForces 939.9 (14%) | findBlocksWithInteractions 559.2 (9%) | applySettleToPositions 213.5 (3%) |
| amber20-stmv | 16591 | computeNonbonded 4563.2 (28%) | gridSpreadCharge 3612.9 (22%) | computeBondedForces 1845.5 (11%) | findBlocksWithInteractions 1767.9 (11%) | computeRange 635.8 (4%) |

### Mixed over single cost map

Attributed us/step, single to mixed, summed over grid shapes. Constraints are applySettle and applyShake to positions and velocities; integrator is integrateLangevinMiddlePart1 to 3.

| Test | GPU busy growth | Constraints | Integrator | Biggest growers |
|---|---:|---:|---:|---|
| gbsa | +117 | +80 (69%) | +34 (29%) | applyShakeToPositions 7.8 to 52.1; applyShakeToVelocities 7.1 to 43.1; LangevinMiddlePart3 5.5 to 19.7 |
| rf | +199 | +178 (89%) | +35 (18%) | applySettleToPositions 10.7 to 66.5; applyShakeToPositions 7.9 to 51.5; applySettleToVelocities 7.7 to 48.3; applyShakeToVelocities 6.0 to 43.5 |
| pme | +192 | +179 (93%) | +35 (18%) | applySettleToPositions 10.7 to 67.2; applyShakeToPositions 8.1 to 52.2; applySettleToVelocities 7.1 to 47.6; applyShakeToVelocities 6.2 to 43.9 |
| apoa1rf | +256 | +192 (75%) | +65 (25%) | applySettleToPositions 11.5 to 70.2; applyShakeToPositions 9.1 to 56.1; LangevinMiddlePart2 11.8 to 37.9 |
| apoa1pme | +259 | +190 (73%) | +65 (25%) | applySettleToPositions 11.6 to 71.6; applyShakeToPositions 9.3 to 55.5; LangevinMiddlePart2 12.0 to 38.2 |
| apoa1ljpme | +285 | +206 (72%) | +65 (23%) | applySettleToPositions 11.8 to 79.0; applyShakeToPositions 9.5 to 59.9; LangevinMiddlePart2 12.2 to 38.6 |
| amber20-dhfr | +202 | +186 (92%) | +36 (18%) | applySettleToPositions 10.7 to 67.2; applyShakeToPositions 8.3 to 55.4; applyShakeToVelocities 6.5 to 48.1 |
| amber20-cellulose | +649 | +401 (62%) | +212 (33%) | applySettleToPositions 25.7 to 213.5; applySettleToVelocities 18.9 to 131.4; LangevinMiddlePart2 29.7 to 111.6 |
| amber20-stmv | +1392 | +901 (65%) | +585 (42%) | findBlocksWithInteractions 1027 to 1768; applySettleToPositions 76 to 507; computeRange 322 to 636; LangevinMiddlePart3 75 to 359 |

Constraints plus integrator explain 95 to 111% of the mixed growth on every test; the rest nets out. The force kernels (computeNonbonded, gridSpreadCharge, computeBondedForces) cost the same in both precisions. On Metal, `mixed` is `double` built from `df64.metal` (589 lines of float-pair emulation, MetalContext.cpp:426 and :440), so every constraint iteration and integrator update runs emulated double math. The constraint kernels show a floor of about 50 to 70 us per dispatch on systems from 7k to 20k waters (SETTLE positions 67 us on pme, 70 us on apoa1), which looks like per-thread latency of a long df64 dependency chain rather than throughput. At single cost, constraints and integrator would take mixed pme from 1.36x to about 1.02x of single. On stmv, findBlocksWithInteractions (+740) and computeRange (+314) also grow, and neither is kernel cost. Both the list rebuild and the PME atom sort run every second step on stmv (the sort because stepsToSort resets to 1 above 15,000 atoms, CommonCalcNonbondedForce.cpp:980). In the single record the two land on the same step: the rebuild's findBlocksWithInteractions (4.0 ms raw) runs beside the sort chain (computeRange 1.25 ms, then the bucket kernels), so each gets half the shared time. In the mixed record they alternate: findBlocksWithInteractions (7.0 ms raw) runs beside gridSpreadCharge and the forward FFT, and the sort's computeRange runs alone. Attributed time per step then grows by (3508 - 2000)/2 = 754 us on findBlocksWithInteractions and (1256 - 626)/2 = 315 us on computeRange, which is the +740 and +314. Which phase a run gets is set by when the first rebuild falls, so kernel deltas on tests where two every-other-step chains overlap need the census's repeats or GPUPROF=kernels (isolated) before they count.

### Integrator and constraints span (native study 1g)

segment.py on the p1 and p2 counters records, integrateLangevinMiddlePart1 through Part3, all steps. The union equals the sum on every test, so these kernels never overlap each other. Sequence on rf, pme and dhfr: Part1, SETTLE velocities, SHAKE velocities, Part2, SETTLE positions, SHAKE positions, Part3; gbsa has no SETTLE.

| Test | Single union us | Mixed union us |
|---|---:|---:|
| gbsa | 31.2 | 147.9 |
| rf | 53.4 | 269.3 |
| pme | 54.7 | 271.7 |
| amber20-dhfr | 55.5 | 280.0 |

Per-kernel medians, single to mixed: on pme, SETTLE positions 10.7 to 68.4, SHAKE positions 8.2 to 52.6, SETTLE velocities 7.8 to 48.8, SHAKE velocities 6.3 to 44.2, Part1 7.2 to 16.0, Part2 6.8 to 19.5, Part3 7.2 to 20.8. rf and dhfr match pme within 5 us per kernel (dhfr's SHAKE velocities is 48.8 mixed); gbsa's SHAKE positions is 7.8 to 52.9. The study's kill line (single rf under 15 us and mixed pme under 120 us) is not met, so the fused integrator stays in. My pme single 54.7 matches the mixed lane's census.

### amber20-stmv benchmark.py (ultra-base, ab.sh)

Rounds 1 (20:50Z) and 2 (22:50Z) of 30 s, median of the two. Round 1 ran at a 1-minute load of 3.6 to 13.0 (backupd and node at 50 to 100% of a core); all three round 2 runs overlapped a build (load 3.5 to 10.2):

| Config | ns/day | Round 1 | Round 2 |
|---|---:|---:|---:|
| Metal single | 21.25 | 21.26 | 21.23 |
| Metal mixed | 19.24 | 19.26 | 19.21 |
| OpenCL single | 18.55 | 18.55 | 18.56 |

Metal/OpenCL 1.145 (rounds 1.144 to 1.146), mixed/OpenCL 1.037, mixed/single 0.905. The rounds agree within 0.3%, so round 3 was stopped at the lead's order (it would have taken a new ticket at the back of the queue); the dedicated window remeasures stmv. prof.py's unrecorded stmv windows give 21.25 ns/day, and experiment 018 had OpenCL at 18.6 on this machine.

### AMOEBA on OpenCL

Not rerun. ultra-plugins/amoeba1 already ran it on ultra-base, 3 rounds of 30 s, with no failures: OpenCL single amoebagk 3.98 ns/day (rounds 4.02, 3.78, 3.98), amoebapme 8.04 (8.13, 6.34, 8.04). In the same run Metal single gave 4.22 and 8.49, Metal mixed 4.39 and 8.31. Load reached 44 during that run, so the spreads are 5 to 22%.

### Probes

- UseBlockingSync, false against true: not timed, because the property does nothing in this tree. MetalPlatform.cpp:134 defaults it to "true" and passes it to the MetalContext constructor (MetalContext.cpp:115), which stores it in `useBlockingSync` and never reads it. MetalEvent::wait always calls waitUntilSignaledValue.
- Nonbonded launch shape (HIP's 40x64 per core against `metal`'s 6x256) and grid cap (12 against 24 thread blocks per core), one hold 23:04 to 23:13Z, 2 rounds of 15 s, 12 of 32 runs during a build, 1-minute load 2.9 to 11.1. prof, nb6x256 and tbpc24 run on my Xcode-beta rebuild of the profiling tree; prof against base prices that tree. Ratios, median of rounds (round range):

| Test | prof/base | nb6x256/prof | tbpc24/prof |
|---|---:|---:|---:|
| gbsa | 0.995 (0.993 to 0.996) | 1.005 (1.004 to 1.006) | 1.005 (1.003 to 1.007) |
| rf | 1.009 (0.996 to 1.022) | 0.996 (0.992 to 1.000) | 0.993 (0.989 to 0.997) |
| pme | 1.006 (1.001 to 1.011) | 0.991 (0.989 to 0.994) | 0.997 (0.996 to 0.999) |
| apoa1pme | 1.002 (1.001 to 1.002) | 0.988 (0.985 to 0.991) | 1.010 (1.005 to 1.016) |

  The profiling tree with GPUPROF unset is within 1% of ultra-base (gbsa 0.5% slower in both rounds; base's rf rounds spread 3.3%). 6x256 is no better than HIP's 40x64 and 1.2% slower on apoa1pme: dead. tbpc24 moves nothing past 1% (apoa1pme +1.0%, rf -0.7%), under the 3% screen line, so lifting the executeKernel cap is not a candidate. GBSA's computeBornSum and computeGBSAForce1 are 35% of gbsa's GPU time and get 3.3x the groups at tbpc24, yet gbsa moves 0.5%, so those two kernels are not limited by the 720-group cap. The tbpc24 census (91086) will show the per-kernel change.
- Grid-cap sweep (playbook open question 10): dropped at 23:23Z. `gpusweep.sh` (tbpc 12, 24, 16 and 32 on apoa1pme and amber20-dhfr, with the Occupancy Manager Target and Shader Launch Limiter counters) was meant to show whether a bigger grid helps; the tbpc24 probe answered that end to end (no), and the tbpc24 census gives the per-kernel view. The tool is also broken: prof.py exits about 6 s after window A, before gpucapture attaches, so gpucapture waits on a dead pid for its 120 s timeout with the lease held (it did in the xctrace hold at 23:21Z). The race and the fix it needs are in the script's header.
- The stmv configs.txt stamps ultra-base "built 2026-09-24T19:38:25Z", while ultra-base/READY reports the Xcode-beta rebuild at 20:36:53Z. Round 1 ran at 20:50Z, after the rebuild, so the stamp is probably stale; infra should confirm.

### Xcode Metal System Trace

/Applications/Xcode.app (27.0) is blocked by its unaccepted license, which needs sudo. Xcode-beta 27.2 works: `xctrace version` gives 27.2 (27B5019j) and lists the Metal System Trace template. `profiler/xtrace.sh` records prof.py inside a Metal System Trace on gbsa, rf and pme single, with GpuProf.h split mode in window B, so the trace names each kernel's encoder, the GPU intervals can be checked against GPUStartTime and GPUEndTime, and windows A and C price the trace itself. It ended with one gpusweep.sh config (apoa1pme, tbpc 12) as a smoke test of gpucapture, which hit the attach race (Probes). Ran 23:18 to 23:20Z; the traces are in xtrace/ on the M3 Ultra, 6 s each.

What the export holds (gbsa trace, `xctrace export --toc`, then `--xpath` per table; `profiler/xschema.py` prints every table's columns and sample rows). The Metal System Trace has about 70 tables. The GPU timeline is `metal-gpu-intervals`: one row per GPU kick with start, duration, channel (Compute, Blit), CPU-to-GPU latency, command buffer id, encoder id and a label. `metal-gpu-execution-points` holds the same kicks as start and end points. There are no per-dispatch times: the driver merges consecutive compute encoders into one kick, and the label lists the merged encoders' labels. Even in window B, where split mode gives every kernel its own labeled encoder, a gbsa step runs as 3 to 4 kicks:

| Kick (window B, gbsa single) | Per step | Median us |
|---|---:|---:|
| sortBoxData, findBlocksWithInteractions, copyInteractionCounts | 1 | 10.3 |
| computeBornSum, reduceBornSum, computeGBSAForce1, reduceBornForce, computeBondedForces, computeNonbonded | 1 | 179.2 |
| (generateRandomNumbers every 4th step), integrateLangevinMiddlePart1 through sortShortList2 | 1 | 50.9 to 58.0 |

In windows A and C (upstream's encoders, no encoder labels) the kicks show as Compute Command 0, Blit Command 1 and Compute Command 2. Consecutive kicks overlap in 13 of 63,341. The shader timeline tables (`metal-shader-profiler-intervals`, `gpu-shader-profiler-interval`) exist but are empty. So the trace settles kick-level questions (how many GPU submissions a step becomes, the gaps between them, CPU-to-GPU latency) but not dispatch overlap inside a kick, which still needs counters mode, a capture replay or the shader timeline. The full schema dump is `profiler/xctrace-schema-gbsa.md`.

Shader timeline. No xctrace flag exposes it: `--show-recording-options` lists only Hangs and Time Profiler for Metal System Trace, with or without `--instrument GPU`, Metal GPU Counters or Metal Application, and a `--recording-options` JSON setting GPU shaderprofiler changes nothing it lists. The switch lives in the template: Metal System Trace.tracetemplate (GPU.instrdst) is a keyed archive whose options dict holds `shaderprofiler: False`, and no template shipped with Xcode-beta 27.2 sets it True. GPU.instrdst names the feature ("Shader Timeline", "Adds Metal GPU Shader Timeline graphs to the thread tracks"), and the trace's gpu-counter-info table records `shader-profiler=0`. `profiler/shadertemplate.py` writes a copy with only that value set True, and `xctrace record --template <path>` loads it. Whether a recording then fills the shader tables is untested until the shader.sh hold runs; `shader-profiler=1` in gpu-counter-info and rows in metal-shader-profiler-intervals would confirm it.

Using the shader-timeline template (any lane, once the check in shader.sh passes):

1. The template is `/tmp/openmm-metal-bench/ultra-profiler/tmpl/mst-shader.tracetemplate` on the M3 Ultra. To make your own, run `python profiler/shadertemplate.py <out>.tracetemplate` with any python 3. It reads Xcode-beta's Metal System Trace template and refuses if the template changed shape.
2. Record under your lease, launch mode only: `xcrun xctrace record --template <template> --time-limit 120s --no-prompt --output <x>.trace --env PYTHONPATH=<dir>/venv/lib/python3.13/site-packages:<dir>/pydeps --target-stdout <x>.txt --launch -- <dir>/venv/bin/python <script> ...`, with DEVELOPER_DIR set to Xcode-beta. Keep the run to a second or two of steps, since the shader timeline samples every kick. `profiler/shader.sh` does this for prof.py and checks that the tables fill before it traces anything else.
3. Export after the lease: `xcrun xctrace export --input <x>.trace --xpath '/trace-toc/run[@number="1"]/data/table[@schema="metal-shader-profiler-intervals"]'`. Each row is one shader's sampled interval: start, sample duration, shader name, pipeline, % of the kick and channel. The shader list in the gbsa trace named shaders by function name (FunctionCompiled signposts, empty labels), so GpuProf.h labels should not be needed. `metal-shader-profiler-shader-list` maps shader names to their PC ranges, and `profiler/xctrace-schema-gbsa.md` lists every column.

Kicks per window (`kicks.py`, single, windows A and C have no GpuProf.h instrumentation; A shown, C's busy and idle within 1 us/step of A). Wall is the host time of the window under the trace; idle is wall minus the kick union.

| | gbsa | rf | pme |
|---|---:|---:|---:|
| Wall us/step (buffers mode, table above) | 304.3 (293.0) | 505.6 (501.7) | 638.3 (639.1) |
| Kicks per step | 4.01 | 4.01 | 4.01 |
| GPU busy us/step, share of wall | 261.7, 86.0% | 455.0, 90.0% | 630.3, 98.7% |
| Idle us/step, share (buffers mode) | 42.6, 14.0% (24.5, 8.3%) | 50.7, 10.0% (45.9, 9.1%) | 8.0, 1.3% (6.9, 1.1%) |
| Gap between kicks: median, p90 us | 0.54, 38.6 | 0.42, 40.0 | 0.42, 0.58 |
| Gaps over 10 us per step, us/step they hold | 0.80, 40.2 | 0.80, 48.2 | 0.03, 6.0 |
| Y end to X' start: median, us/step | 0.54, 10.2 | 35.8, 46.2 | 0.46, 6.3 |
| X end to Y start: median, us/step | 0.54, 13.8 | 0.42, 1.1 | 0.46, 0.6 |
| Inside X, blit to sortBoxData kick: median, us/step | 0.88, 17.8 | 0.42, 2.4 | 0.42, 0.6 |

A step is 4 kicks: buffer X runs Compute Command 0 (the integrator, 52 to 58 us on gbsa), Blit Command 1 and Compute Command 2 (sortBoxData, findBlocksWithInteractions, copyInteractionCounts), and buffer Y runs one compute kick (forces). The idle gap from buffers mode shows up without instrumentation. On rf it is one gap per step after Y, median 35.8 us against gaps.py's 33.4. On gbsa the two gaps between buffers match gaps.py's means (13.8 against 13.4 before Y, 10.2 against 9.8 after it). The rest of gbsa's idle, 14 to 18 us/step, falls inside buffer X between the blit and the sortBoxData kick. It is a tail: over 10 us on 2061 of 5252 steps, 0.9 us median. Buffers mode counts time inside a command buffer as busy, so it could not see this. The trace also adds 11 us/step to gbsa's wall against buffers mode (4%, and buffers mode itself costs 1.3%), so this in-buffer gap may be trace overhead. The kicks cannot tell. Window B (split mode) adds a 50 to 88 us gap between the forces kick and the integrator kick on gbsa and rf: split mode's own cost, which B/A already prices.

The stage-boundary counters do work on this OS. Some reports say they write zeros on macOS 26 and later; here the p1 and p2 records hold 1.66M encoder samples with 0 invalid, and the sample clock matches GPUStartTime to 41 ns.

## Levers, ranked

f is the share of the unrecorded Metal single step a lever removes; the ratio is Metal/OpenCL single on the Ultra after it lands (now = prof.py unrecorded wall against 018's OpenCL numbers). From levers.py.

| Test | Now | L1 spread 2x | L2 findBlocks 2x | L3 host gap closed | L4 short sort 48 to 8 us | L5 computeRange parallel | L6 bucket sort 2x | L1 to L6 together | L7 bonded 2x | L8 encoder overlap | L9 nonbonded 10% |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| gbsa | 1.02 | 0% 1.02 | 3% 1.05 | 8% 1.11 | 2% 1.04 | 0% 1.02 | 0% 1.02 | 14% 1.19 | 4% 1.06 | 0% 1.02 | 2% 1.04 |
| rf | 1.06 | 0% 1.06 | 15% 1.24 | 9% 1.17 | 8% 1.15 | 0% 1.06 | 0% 1.06 | 32% 1.55 | 2% 1.08 | 0% 1.06 | 3% 1.09 |
| pme | 1.04 | 8% 1.13 | 8% 1.13 | 1% 1.06 | 7% 1.12 | 2% 1.07 | 1% 1.06 | 27% 1.43 | 3% 1.08 | 5% 1.10 | 2% 1.06 |
| apoa1rf | 1.08 | 0% 1.08 | 12% 1.22 | 1% 1.09 | 0% 1.08 | 1% 1.09 | 2% 1.10 | 16% 1.28 | 6% 1.15 | 1% 1.08 | 4% 1.13 |
| apoa1pme | 1.08 | 11% 1.22 | 5% 1.14 | 1% 1.09 | 0% 1.08 | 3% 1.11 | 3% 1.11 | 23% 1.40 | 7% 1.17 | 5% 1.14 | 2% 1.11 |
| apoa1ljpme | 1.14 | 14% 1.32 | 3% 1.18 | 0% 1.15 | 0% 1.14 | 8% 1.24 | 5% 1.20 | 30% 1.64 | 5% 1.21 | 2% 1.16 | 2% 1.16 |
| amber20-dhfr | 1.02 | 9% 1.12 | 6% 1.08 | 1% 1.03 | 7% 1.09 | 3% 1.04 | 2% 1.03 | 27% 1.38 | 3% 1.05 | 3% 1.04 | 2% 1.04 |
| amber20-cellulose | 1.14 | 13% 1.32 | 4% 1.19 | 1% 1.15 | 0% 1.14 | 3% 1.17 | 2% 1.16 | 23% 1.48 | 8% 1.24 | 6% 1.22 | 3% 1.17 |
| amber20-stmv | 1.14 | 16% 1.36 | 3% 1.18 | 1% 1.15 | 0% 1.14 | 2% 1.17 | 3% 1.17 | 25% 1.52 | 6% 1.22 | 6% 1.22 | 3% 1.18 |

1. L1, gridSpreadCharge (plus finishSpreadCharge) 2x: 8 to 16% on all six PME tests, the largest single lever on the big systems. The kernel runs 46,080 threads for 1.07M atoms on stmv because of the 720-threadgroup cap. pme lane.
2. L2, findBlocksWithInteractions 2x: 15% on rf, 12% apoa1rf, 8% pme, 6% dhfr. 019's SIMD kernel was 2.3 to 3.1x in isolation. The explicit tests rebuild on every second step (dhfr every third), so a looser padding that rebuilds less also counts here. nblist lane.
3. L3, host gap: 8% on gbsa, 9% on rf, about 1% elsewhere. One host event wait per step splits the step into 2 buffers. On rf the chain from X's end to X' start (wake 71, encode 23, commit to scheduled 78, scheduled to start 34 us) outlasts Y by about 30 us, so the wake and the commit-to-start latency are the targets, not host encoding. dispatch lane.
4. L4, sortShortList2 from 48 to 8 us: 7 to 8% on rf, pme and dhfr. nblist lane (NB_SORT2).
5. L5 and L6, the PME atom sort: parallel computeRange removes 8% on apoa1ljpme and 2 to 3% elsewhere; a 2x bucket sort another 2 to 5%. nblist and pme lanes.
6. L7, computeBondedForces 2x: 6 to 8% on apoa1rf, apoa1pme, cellulose and stmv. It also runs at the 720x64 cap; the tbpc24 probe will say whether the cap is the reason. The same cap clips gbsa's computeBornSum and computeGBSAForce1 (35% of gbsa's GPU time) from 2400 groups to 720. The tbpc24 probe (23:13Z) says the cap is not the limit: 24 per core moves gbsa +0.5%, apoa1pme +1.0% and rf -0.7%. Had lifting the cap won, it would have been a one-line candidate: numThreadBlocksPerComputeUnit at MetalContext.cpp:159, which already scales with the core count. numThreadBlocks also sizes the energy buffer (MetalContext.cpp:328, the max of it x 64 and the nonbonded's 40 per core x 64), so up to 40 per core the buffer and its reduction stay the same size.
7. L8, encoder overlap: counters mode shows the GPU could save 5 to 6% on pme, apoa1pme, cellulose and stmv by running independent kernels concurrently. Plain one-encoder-per-dispatch does not get it (split mode), so this needs a concurrent dispatch type with explicit barriers. dispatch lane.
8. L9, computeNonbonded: 17 to 43% of the step and the top kernel on 6 of 9 tests; each 10% faster is worth 2 to 4%. nonbonded lane.
9. Mixed only: SETTLE, SHAKE and the LangevinMiddle kernels in df64 are the whole mixed penalty (+117 to +285 us/step up to apoa1ljpme, +1.4 ms on stmv). mixed lane.

L1 to L6 together, if each lands at the size assumed: Metal/OpenCL 1.19 (gbsa) to 1.64 (apoa1ljpme), 1.38 to 1.55 on the dhfr-size and stmv tests. L7 to L9 add another 14 to 17% on apoa1pme, cellulose and stmv. No single lever moves more than 16% of the step. Nonbonded, spread and bonded together are 58 to 74% of the step on the four big PME tests, so a 2x overall needs all three.

## Learnings

- Retain the MTLCounterSet taken from `device->counterSets()`. The array is autoreleased, and a CounterSampleBufferDescriptor that points at the dangling set segfaults in objc_setProperty_atomic.
- On macOS 27 on the M3 Ultra, stage-boundary timestamps are nanoseconds on the GPUStartTime clock. Check against a buffer's GPUStartTime before applying any timebase.
- Per-encoder timestamps overlap once each dispatch has its own encoder. Rank kernels by attributed time, never by the raw sum, or kernels next to independent work (findBlocksWithInteractions here) look 2x bigger than they are.
- Counters mode is not a neutral observer: it slows small systems 1.3 to 2.2x on the host side and speeds large ones 4 to 6%. Take step totals from buffers mode and only shares from counters mode.
- When the lease queue is deep, wrap a whole ab.sh run in one lease.sh (the nested lease.sh calls run at once). ab.sh on its own takes a new ticket at the back of the queue for every round and test.
- benchmark.py's amber20-dhfr reads a NetCDF restart file, so the venv needs scipy.
- Pull every number you send to another lane from the records with a script, not from memory. Of the numbers I sent at 21:30Z from notes, a rounding (9.3 for 9.2), a sample count (1.9M for 1.66M) and an unchecked claim (the worst gap steps are reorder steps; they are not) were wrong, and each needed a correction message.
- `xctrace record --launch` has `--env` and `--target-stdout`; pass PYTHONPATH to the venv's site-packages, in case xctrace resolves the venv's python symlink and loses the venv.
- Gate every profiling-only code path on the profiling switch, including ones that look harmless, like building pipelines from a labeled descriptor. Probe arms that set no switch must run the upstream path, or they price the probe instead of the change.
- A patch that adds or removes a .metal kernel needs cmake rerun (the kernel list is a configure-time glob), and after removing one, delete the generated MetalKernelSources files too: ninja doesn't rerun a step whose input only disappeared, so the removed kernel's text stays in the plugin.
- Stop a job only by the pid recorded when it started, never by a pgrep, pkill or ps match (RULES line 57, which reached me at 23:16Z). A job that spawns children as it goes (ab.sh queues a new lease.sh per round) has to be stopped at its own recorded pid, before it spawns the child you don't want.
- Don't classify slow dispatches by a multiple of the fastest one. With encoders overlapping, the fast findBlocksWithInteractions dispatches stretch past 2x the minimum, so the 2x rule put apoa1pme at 75% rebuilds when the true rate is 50%. Split at the largest ratio gap between sorted durations (summarize.py's slow_mode) and check the gap is wide (8x or more here).
- `$D` inside a double-quoted `ssh host "..."` expands on the laptop, where D is unset, so a launch meant for `$D/tools/x.sh > $D/x.out` becomes `/tools/x.sh > /x.out` and fails silently under nohup. Send remote scripts through `ssh host 'sh -s' <<'EOF'` and check that the ticket appears.

## Log

- 19:22Z Started. Read RULES.md, 024's GpuProf.h, gbprof patch and analyzers, 019 findblocks.
- 19:50Z Profiling build on the Studio (own venv, -j8). First counters run segfaulted in objc_setProperty_atomic under gpuprof::nextSample: the "timestamp" CounterSet came from an autoreleased array and was dangling. Fixed with retain.
- 20:06Z Block 1 (p1): single, buffers and counters, 9 tests. Per-step table sent to the lead 20:15Z. summarize.py first treated counter ticks as mach ticks, which made kernel times 41.67x too large; the clock check above showed nanoseconds and all p1 counters files were resummarized.
- 20:10Z to 20:50Z Lease starvation: ultra-plugins held the lease back to back and load ran 14 to 44 from builds. Told the lead 20:35Z. Trimmed the probes to base, prof, nb6x256 and tbpc24.
- 20:50Z stmv ab.sh round 1 (3 configs).
- 20:56Z to 21:09Z Block 2 (p2): dhfr single buffers, mixed buffers and counters on 9 tests, split on 4.
- 21:14Z The nonbonded lane holds the lease by hand since 21:08Z with 12 lease.sh waiters queued; told the lead. Dropped my AMOEBA rerun in favor of ultra-plugins/amoeba1. Queued the probes as one lease.
- 21:20Z Added attributed kernel times to summarize.py (overlapping encoder time split evenly), resummarized p1 and p2, wrote levers.py. This cut findBlocksWithInteractions' share roughly in half on the big systems and dropped the "5% serial barrier" reading: the split-mode runs show the plain split does not speed anything up.
- 21:28Z Rebuilt the profiling tree with Xcode-beta 27.2 in src/build-xb (nice 10, -j6), per the toolchain rule. Wrote gaps.py and segment.py, exported gpuprof.patch, and gave profile.sh a PY= override so other lanes can profile their own build.
- 21:30Z Sent data: 1g union to the lead and mixed, the mixed census to mixed, PME kernel medians to pme, the gap split to dispatch, nonbonded, bonded and interpolate shares plus the recipe to atomics. 21:34Z rechecked every number against the records and sent three corrections (above).
- 21:36Z Queued xctrace (xtrace.sh) under lease.sh. Asked research for the 1e patch path and the lead whether to stay past 22:22Z.
- 21:46Z Routed findings per the lead: spread shares and the grid cap to pme, the bonded grid cap to atomics, findBlocks and the short sort to nblist (df64 went to mixed and the host gaps to dispatch at 21:30Z). Told the lead the playbook's "GBSA runs 2560 per core" is wrong: executeKernel clips GBSA to 720 groups.
- 21:50Z Rebuilt with labeled pipelines and encoders for gpudebug and xctrace. The first version built every pipeline from a labeled descriptor even without GPUPROF, which would have changed the path the probes time, so 21:52Z rebuilt with the label gated on GPUPROF (Method). Checked: MetalContext.cpp recompiled, the plugin relinked and installed, and all 8 probe files hash the same on the Studio as in the worktree.
- 21:55Z Wrote gpusweep.sh, pointed xtrace.sh at split mode with a gpusweep smoke config, regenerated gpuprof.patch, and queued the grid-cap sweep as two tickets (apoa1pme, amber20-dhfr).
- 22:04Z Owner: no freeze and no cap. Lead's order: tbpc24, then a census of every gated candidate and of ultra/integrated, then the xctrace export schema. Wrote census.sh, census.py (tested on synthetic two-arm data), mkcensus.sh and xschema.py; queued the tbpc24 census. Told the lead the census is ready for each candidate as it passes the gate.
- 22:09Z 1e built (prefix-1e, prefix-1e-rsqrt) and queued. build-patch.sh now reruns cmake after the patch and after the revert, since the kernel list is globbed at configure time. The first revert left build-xb's generated MetalKernelSources.h with the kill kernel in it: ninja does not rerun a step when one of its inputs is only removed. The installed prefix was never touched. The revert now deletes the generated MetalKernelSources files, and build-xb was regenerated by hand and checked clean (no gbsaObc in the header, 3 computeGBSAForce1 strings in the plugin, as in prefix).
- 22:25Z Research caught my rebuild classifier overcounting (apoa1rf 71%, apoa1pme 75%, dhfr 38% against its replay's 50, 50 and 33%). Confirmed with a gap split of the raw findBlocksWithInteractions durations on all 18 p1 and p2 records: 50.2% on every explicit test, 33.7% dhfr, 8.0% gbsa. The 2x-min rule counted overlap-stretched early returns. Replaced summarize.py's over-2x-min column with the gap split (Slow mode), fixed the per-kernel facts and L2, and sent the corrected rates and per-rebuild costs to research and nblist.
- 22:28Z Explained the stmv mixed growth in findBlocksWithInteractions and computeRange (ledger 547) from the p1 and p2 records: the rebuild and the PME sort both run every second step, and the single run had them on the same step while the mixed run had them alternating. The attributed arithmetic matches both deltas to within 15 us (Mixed over single cost map).
- 22:32Z census.py reported command buffer busy time, which counters mode inflates (560 us against a 292 us kernel union on gbsa); it now reports the kernel union. Rechecked end to end on a two-arm set built from the p1 gbsa record, and synced both tools to the M3 Ultra (hashes match).
- 22:34Z Lead: time the GBSA kill builds end to end against ultra-base on gbsa single and mixed in one hold. The builds from 22:09Z are research's patches unchanged (same sha1 as the lab copies), so no rebuild; wrote gbsakill.sh and queued it as ticket 23181. 1e (30130) stays queued for the forces check and the per-kernel census.
- 22:35Z Lead: 1e is the kill test, so no second ticket. Folded gbsakill.sh into 1e.sh (forces, then the ab.sh timing, then the counters census, one hold) and cancelled ticket 23181 before it ran (TERM to my own lease.sh waiter; its ticket is gone from the queue).
- 22:36Z Lead: 4 arms x 3 rounds x 2 precisions (24 runs) could pass the 20 minute cap. Dropped the ultra-base arm and cut to 2 rounds in gbsakill.sh (12 runs), still inside 1e's hold (30130); synced and hash-checked.
- 22:38Z Lead: stop the unwrapped stmv ab.sh (pid 25022) after round 2 unless rounds 1 and 2 differ by more than 3%, since round 3 would take a new ticket at the back. A watcher on the laptop waits for ab.sh to queue round 3, compares ns/day per config, and if all agree within 3% stops the round 3 waiter, after which ab.sh ends. Round 2 is next in the queue after ultra-plugins.
- 22:56Z stmv round 2 done; rounds agree within 0.3% (metal 21.26/21.23, mixed 19.26/19.21, opencl 18.55/18.56). The watcher stopped the round 3 waiter (lease.sh 35483) and ab.sh 25022 ended. It found that waiter with `pgrep -P 25022 -f "round 3"`, limited to my ab.sh's children. That was before the lead's pid-only rule reached me (23:16Z), and I won't stop anything that way again (Learnings).
- 23:13Z Probes done: tbpc24 dead (all four tests within 1%), 6x256 dead (0.988 to 1.005), the profiling tree within 1% of ultra-base. Sent tbpc24 to pme, atomics and the lead, the shape result to nonbonded.
- 23:23Z Lead: the xctrace hold (45036) sat idle from about 23:21Z. Its gpusweep smoke config started `gpucapture --pid` after prof.py had already exited, and gpucapture waited out its 120 s timeout. The sweep tickets (34111, 34247) would have hit the same race four times each, and they no longer decide anything, so I stopped both by their recorded pids at 23:23:30Z (34111 had held the lease for 22 s), and workloads took the lease at 23:23:35Z. The sweep's `timeout 120 gpucapture` (60328) ran in its own process group, outside lease.sh's group stop; I hadn't recorded its pid, so I left it for its timeout. Retired gpusweep.sh with the race in its header. The xctrace part itself worked: gbsa, rf and pme single traces in xtrace/.
- 23:30Z Lead: drop the tbpc24 census. Stopped 91086 by its recorded pid before it ran; its ticket is gone. 1e (30130) is my only ticket.
- 23:32Z xctrace export schema (lead's order 3). xschema.py first died on a table attribute holding double quotes (swift-table), which broke its XPath, and one failed table aborted the run; it now addresses tables by schema and position and skips a failed export. metal-gpu-intervals gives per-kick times only; the driver merges encoders into kicks, so no per-dispatch timeline comes out of these traces (Xcode Metal System Trace). Told the lead.
- 23:43Z Lead's two CPU-only questions (Xcode Metal System Trace). Shader timeline: no xctrace flag; the template's shaderprofiler option is off, and a copy with it on (tmpl/mst-shader.tracetemplate) loads but is untested, with about 3 minutes of hold for apoa1rf base against 4be61f9b6. Kick table from the existing traces (kicks.py): the buffers-mode idle holds without instrumentation. rf is 10.0% idle, one 36 us gap per step after the forces kick; gbsa is 14.0%, the 8% between buffers plus 14 to 18 us/step inside buffer X that may be trace overhead; pme 1.3%. Told the lead, and noted that the 8 to 9% comes from buffers mode, not counters mode. Copied the export schema to profiler/xctrace-schema-gbsa.md.
- 23:53Z Lead: go on the shader-timeline hold, launch mode, gbsa check first. Synced 4be61f9b6 into ultra-profiler/words and built it with infra's build.sh (already -j20, nice 10) by 23:46Z. Its plugin md5 (a749818e) differs from atomics' gate build (978e3bbc, ultra-atomics/prefix) only by two embedded __FILE__ paths: `strings` differ in those two lines alone, both are 3,281,112 bytes, and both BUILT files give src hash eb59ec2f with the same toolchain. The longer path shifts later sections by 8 bytes, so the code bytes differ too. Wrote shader.sh (the hold) and shadertemplate.py (rebuilds tmpl/mst-shader.tracetemplate byte for byte), and prof.py now prints which openmm and plugin it loaded. Checked that PYTHONPATH picks each build's own openmm and plugin even from the resolved python binary. Queued as lease.sh pid 74311.
- 23:58Z nonbonded asked how to get per-kernel times on an install with no hooks (6df2b8bcb against exp 019's p0metal, for an M2 request to infra). gpuprof.patch fails `git apply --check` on every hooked file at 361452c5c and at 33728aa53 (checked in a temporary index, no build), so it would need a hand port. The shader template is the only route that needs no hooks, and it is untested (74311), with M2 support unknown. The capture replay (gpudebug) is unproven here. Told nonbonded that step times are the only proven route until 74311 runs.

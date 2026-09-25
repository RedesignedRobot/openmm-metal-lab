# Dispatch lane

Worktree /Users/amir/code/mini/ultra-dispatch, branch ultra/dispatch from 6df2b8bcb. Studio scratch /tmp/openmm-metal-bench/ultra-dispatch. Started 2026-09-24 19:23Z, hard cap 23:53Z.

## Submission path at 6df2b8bcb

- One open command buffer and one serial compute encoder per queue. The encoder ends at blits (copyTo), event signals and waits, and commits.
- Per step on the benchmark systems there is one host wait: the neighbor list count. prepareInteractions ends the first buffer (X: second half of the previous step's integration, the first half of this one, the list build) with the count event. The force kernels go into Y, the host commits Y, waits on X's event, reads the count, then encodes the rest. 024 measured gbsa at X 66 us and Y 179 us GPU with a 279 us step after the event-wait fix, so about 30 us of the step is outside those two buffers.
- Every dispatch sets every argument (setBuffer or setBytes) and the pipeline.

## Plan

1. Ceiling probe, lab-only env knob DISPATCH_MODE: serial (base), barrier (concurrent encoder, barrier before every dispatch), none (concurrent, no barriers, wrong physics, upper bound on dispatch serialization cost), auto (concurrent, barrier only on a read/write hazard from pipeline reflection access).
2. Per-buffer GPU busy vs step time on gbsa, rf, pme, amber20-dhfr.

## Log

- 19:30Z. Studio tree: source from the mini's git (`git archive 6df2b8bcb` over ssh, the laptop link does 150 KB/s), lane edits overlaid with tar. Build script dispatch/build.sh (lab dir experiments/028-ultra-max/dispatch). Python module stays in build/python/build/lib*, wrapper /tmp/openmm-metal-bench/ultra-dispatch/py sets PYTHONPATH, DYLD_LIBRARY_PATH and OPENMM_PLUGIN_DIR. Amber20 suite extracted into the tree's examples/benchmarks/Amber20_Benchmark_Suite from ultra-base's tarball.
- Probe build (uncommitted): DISPATCH_MODE knob as planned, VkFFT always gets a serial encoder since it dispatches its passes with no barriers. DISPATCH_STATS=1 prints dispatches, barriers, commits and the GPU busy fraction (sum of buffer GPU times over the GPU span, buffers committed after the first 5 s) when the queue is destroyed.
- 19:58Z, probe1 forces (results on the Studio, ultra-dispatch/results/probe1-forces-serial-barrier-none.txt). serial and barrier match 025 to 4 digits (gbsa 2.468e-05, rf 2.213e-05, pme 2.048e-05). none: gbsa rel|dF| 0.85, rf 0.83, pme a GPU page fault. So Metal does not order dispatches inside a concurrent encoder for tracked buffers, and a barrier-free ceiling can't be benchmarked. The first version of probe1 stopped there (set -e); probe1b drops "none".
- Single force evaluation: gbsa 36 dispatches in 11 commits, rf 29 in 11, pme 47 in 12.
- Lease: the stock 20 s poll lost the lease race twice in 15 minutes; leased.sh polls every 2 s now.
- 20:30Z. Switched to the infra tools (ultra-tools/build.sh, ab.sh, gate.sh). Tree rebuilt with tools/build.sh, src/.commit "6df2b8bcb+probe-uncommitted", lane files checked with git hash-object against the laptop. Screen launched: ultra-dispatch/screen-modes, 2 x 15 s, gbsa rf pme apoa1rf apoa1pme apoa1ljpme amber20-dhfr, base vs barrier vs auto.
- Profiler lane block 1 (lanes/profiler.md): GPU idle per step is 24.5 us on gbsa (8.3%), 45.9 on rf (9.1%), 1% or less elsewhere. One encoder per dispatch made apoa1pme, cellulose and stmv 4 to 6% faster (Metal overlaps encoders where its hazard tracking allows), so the serial encoder's barrier after every dispatch costs about 5% on large systems. That is what DISPATCH_MODE=auto targets.
- 024 found spinning on the event 9 us faster per gbsa step than waitUntilSignaledValue, so the host sits on the critical path on gbsa: after the count wait it must encode the rest of the step and the next step's first half before the next commit. Probe 2 (tree ultra-dispatch/t2): DISPATCH_EARLY=1 commits at the start of beginComputation, so the GPU runs the integration kernels while the host encodes the list build.
- 20:40Z to 21:10Z, screen2 (base, auto, early, autoearly), gbsa round 1 only before I stopped it (lease queue of about 10 lanes, 25+ minutes per ticket). Host clock ns/day, load 3.8 to 6.6: base 1244.21, auto 1142.92 (0.919, 74% of dispatches needed a barrier), early 1175.69 (0.945, 3 commits per step), autoearly 1136.75 (0.914). Early is a dead end: its extra command buffer costs about 16 us per gbsa step, the opposite of what I wanted. The DISPATCH_STATS counters on that run: 20.2 dispatches per step, and the host spends 13.35 s of 15.8 s in event waits, so it is busy about 47 us per step and is not the critical path on gbsa. The profiler's 24.5 us idle per gbsa step fits a fixed cost per command buffer (about 12 us times 2 buffers).
- 21:12Z. Candidate onebuf (branch cand/onebuf, 87385210d): MetalEvent::signal() puts the event in the open command buffer without committing, and prepareInteractions() uses it for the count event, so the list build and the force kernels share one buffer that computeInteractions() commits before the count wait. One commit per step with a neighbor list (TestMetalCommandBatching tightened from 2.1 to 1.1). Every other event keeps enqueue(), which commits; a lazy commit in wait() for all events would have delayed the PME queue and download queues. 20 lines added, 7 removed. Built in t2 (probe tree reused for its build dir).
- 21:22Z. RULES.md changed: no outer lease around ab.sh or gate.sh, screen only the targeted tests. I had wrapped gate plus screen in one lease.sh; stopped those waiters (never held) and relaunched unwrapped: gate-onebuf.sh (TestMetalCommandBatching on t2, then gate.sh --quick t2), screen3 (gbsa, rf; base vs one, 2 x 15 s), gate-probe.sh (forces with DISPATCH_MODE=perenc, then auto, on the probe tree), screen4 (apoa1pme, amber20-cellulose; base vs auto vs perenc). perenc is a new probe mode: a serial encoder per kernel dispatch, which is what the profiler's counters mode did when it measured apoa1pme 0.960, cellulose 0.940 and stmv 0.944 against normal batching. The probe tree is rebuilt as "6df2b8bcb+probe-perenc-uncommitted", MetalQueue.cpp checked with git hash-object against the laptop copy (81798dc3).
- Screen targets for onebuf are gbsa and rf: the profiler's idle gap is 8.3% and 9.1% there and at most 1.2% on the rest, so onebuf can't show 3% elsewhere.
- Profiler counters for gbsa (p1/gbsa-single-counters.sum): 20.25 dispatches per step, of which 16 run under 9 us each (about 106 us of the 295 us kernel sum). calcCenterOfMassMomentum plus removeCenterOfMassMomentum cost 12 us per step, the three LangevinMiddle parts plus the two SHAKE kernels 31 us, copyInteractionCounts 1x1 3.4 us. Per-dispatch fixed cost is the next ceiling on small systems, and only fusion cuts it.
- 21:30Z. Lead's review and the native design study (research/2026-09-25-metal-native-design.md, roadmap 1c) arrived: stop DISPATCH_EARLY, the concurrent encoder is dead (auto dropped from my screens, its forces gate cancelled), build a poll wait for the count event, and probe the wait-free step. I stopped screen3, the old screen4 and both gates before they got the lease, so none of them used GPU time.
- Branches now (none pushed yet):
  - cand/onebuf cfc9547f3: the one-buffer change, amended so MetalNonbondedUtilities holds the count event as std::shared_ptr<MetalEvent> (no casts). 23 lines added, 9 removed.
  - cand/poll 17fc67494 (on onebuf): MetalEvent::poll() checks signaledValue() every 10 us (usleep), stops if the buffer completes or fails, then std::atomic_thread_fence(acquire). computeInteractions() uses it for the count. 16 lines added, 1 removed.
  - probe/wait 99aa5dbd5 (on poll, lab only): DISPATCH_WAIT=block (onebuf's blocking wait), none (commit per step, no count wait, maxTiles = totalTiles, maxSinglePairs = 20 x numAtoms, last counts printed at teardown; run-ahead bounded only by Metal's 64 command buffers, not the design's N-2 poll).
- Trees: t2 = cand/poll, t4 = probe/wait, both BUILT 21:31Z. The top tree (ultra-dispatch/) stays the old probe with DISPATCH_MODE, now including perenc.
- 21:31Z queued: gate-poll.sh (TestMetalCommandBatching, then gate.sh --quick t2), screen5 (gbsa, rf, 2 x 15 s: base, one, poll, none), screen4 (apoa1pme, amber20-cellulose, 2 x 15 s: base, perenc).
- 21:44Z. cand/waitfree e492312b5 (on poll), the production form of the wait-free step. The list can't overflow when it has room for every tile and single pair it could hold: tiles are at most totalTiles, since each block's warp packs atoms from the blocks after it (findBlocksWithInteractions loops block2 over block1+1 to NUM_BLOCKS), and single pairs at most MAX_BITS_FOR_PAIRS x 32 x totalTiles. When those arrays fit in recommendedMaxWorkingSetSize/256, initialize() allocates them and computeInteractions() commits without the signal and the wait; the lagged pinned count only drives the reorder heuristic. Multiple contexts and numTilesInBatch > 1 keep the wait. maxBits moved into getMaxBitsForPairs() so initialize() can use it. 58 lines added, 37 removed (24 of each are the maxBits move).
- Admission, measured working sets: M3 Ultra 83494174720 B (budget 326 MB), M2 5726633984 B (budget 22 MB). gbsa (78 blocks, no pair list under GBSA) needs 0.4 MB and is admitted on both. rf, pme and amber20-dhfr (737 blocks, maxBits 4) need 36 MB of tiles plus 279 MB of pairs, 314 MB: admitted on the Ultra only. apoa1 and larger keep the poll wait everywhere. The pair bound is about 700 times the real pair count, which is the cost of an overflow that can't happen; a kernel that spills overflowing pairs into tiles would shrink it, but findInteractingBlocks is the nblist lane's file.
- Tree t5 = cand/waitfree, build started 21:44Z. gate-waitfree.sh: TestMetalCommandBatching plus md100.py (forces against Reference after 100 and 200 LangevinMiddle steps on gbsa, rf, pme, t5 and ultra-base, one correctness hold), then gate.sh --quick t5.
- 21:47Z. Lease queue moves about one ticket per 4 minutes with about 20 tickets waiting, so each sequential hold costs about an hour of wall time. Cancelled screen4 (perenc) before it got the lease, to keep my holds for dispatch candidates. screen5 keeps "none" as the stand-in for waitfree's timing.
- 22:02Z. Adversarial review of e492312b5 (fresh-context Opus reviewer, read-only): no wrong-force path found; claim 1 (tiles at most totalTiles, pairs at most maxBits x 32 x totalTiles) confirmed from the kernel. Fixed in the amended commit a08243d4b: (a) the budget was per context, so 64 replica contexts could put a quarter of the working set into lists; it is now 1/256 of recommendedMaxWorkingSetSize minus currentAllocatedSize, so admission stops once the process holds a lot. (b) The reorder heuristic's baseline (tilesAfterReorder, read on the step after a reorder) would have come from the pre-reorder list, since the host no longer waits; the host now signals and polls on steps with getStepsSinceReorder() == 0, one wait per 250 or more steps. (c) The numTilesInBatch check was dead code (the bound holds for several warps per block too); removed. Not fixed, noted: the resize path is untested on small systems now that they are admitted; the CCMA converged flag is cleared by the host without a finish (pre-existing race between two CCMA calls in a step, only after a 150-iteration non-converged call); command buffer errors surface later with run-ahead.
- a08243d4b: 57 lines added, 35 removed. t5 rebuilt 22:02Z; gate-waitfree.sh still waiting for its first hold, so it gates the amended tree.
- 22:25Z. rf boundary characterized from the profiler's base records (ultra-profiler/p1/{rf,gbsa}-single-buffers.rec.gz, no GPU time), with ultra-dispatch/bgaps.py plus a finer binning. For each pair of consecutive command buffers I binned the idle gap by the lead: how long before the earlier buffer's GPU end the next one was committed. The idle gap is Metal's commit-to-start latency minus that lead, and a boundary costs nothing once the lead passes about 110 us:

| Lead (us) | rf share | rf idle mean | rf idle median | gbsa share | gbsa idle mean | gbsa idle median |
|---|---:|---:|---:|---:|---:|---:|
| 0-25 | 1.3% | 113.8 | 113.9 | 0.2% | 117.3 | 105.4 |
| 25-50 | 1.5% | 98.7 | 88.7 | 0.6% | 87.6 | 85.4 |
| 50-75 | 9.4% | 59.0 | 50.7 | 1.3% | 50.7 | 37.6 |
| 75-100 | 31.5% | 30.5 | 18.5 | 6.4% | 11.2 | 0.5 |
| 100-125 | 5.2% | 14.4 | 0.5 | 28.2% | 6.4 | 0.5 |
| 125-150 | 0.3% | 1.1 | 0.5 | 13.6% | 12.6 | 0.5 |
| 150-300 | 23.8% | 0.6 to 3.9 | 0.5 | 44.0% | 1.6 to 16.4 | 0.5 |

  So rf's 33 us median at the force-to-integration boundary is not a GPU switch cost: when the next buffer is already committed 110 us or more ahead, the GPU starts it 0.5 us after the previous one ends. On rf the host commits X' about 85 us before Y ends (wake 71 + encode 23 against Y's 179), so about 25 to 35 us of the 110 us commit-to-start latency shows. Poll should take most of it (it cuts the wake), and waitfree all of it (commits run steps ahead). gbsa has a residual mean of 6 to 16 us even at long leads, with a 0.5 us median, so a tail of slow starts that isn't lead-bound.
- 22:14Z. Lead: no freeze, the program runs continuously. Keep bar for waitfree is 3% or more over poll on gbsa or rf. Order: poll through the full gate, the waitfree-vs-poll screen, the rf boundary, then a splitPass() API for pme. onebuf cfc9547f3 and poll 17fc67494 stay fixed (pme builds on them). Queued: screen6 (base, poll t2, wf t5; gbsa and rf; 2 x 15 s; one wrapped lease.sh hold per the new queue rule, ticket 63261) and the full gate on t2 (gate-poll-full.out; replaced gate-poll.sh before its first hold). gate.sh names its tickets after the dir basename, so they show as t2-... and t5-... in lease.sh --status.
- Profiling trees for the boundary check: prof/poll 6980a79d1 (t6) and prof/waitfree cc6c887a2 (t7), each the candidate plus profiler/gpuprof.patch without its HD_NB env hunk, and with gpuprof::Wait in both MetalEvent::wait() and poll(). Lab only. prof-dispatch.sh runs profiler/profile.sh buffers mode on rf and gbsa for both in one timing hold (prof1.out, queued after the t6/t7 builds). Read with bgaps.py (any number of buffers per step; profiler's gaps.py assumes two).
- 22:20Z. M2 reading of the same curve (lead's ask). Branch prof/base 188840b78 (6df2b8bcb plus the full profiler/gpuprof.patch, lab only), synced and built with m2sync.sh and m2build.sh in /Users/amir/lab/ultra-m2/dispatch-prof. m2prof.sh took the M2 lease (owner "ultra-m2 ... dispatch gpuprof buffers rf,gbsa single") after checking for builds, ran prof.py buffers mode on rf and gbsa single against ultra-m2/base/benchmarks at nice 0, and released it. Load average 5 to 6 on the M2 during the run, memory 76% free. Records in the M2's dispatch-prof/prof/.

| M2 base | us/step | GPU busy | boundaries with lead over 300 us | idle X to Y median | idle Y to X' median |
|---|---:|---:|---:|---:|---:|
| rf | 1382 | 93.7% | 99.8% | 39.5 | 45.3 to 47.0 |
| gbsa | 867 | 91.6% | 99.6% | 17.5 to 21.0 | 46.4 to 46.5 |

  X is the integration plus list build buffer (14 to 17 dispatches and the count blit), Y the force buffer. The M2's constant is a different kind of cost from the Ultra's: the host commits every buffer 600 us or more before the GPU needs it, and the GPU still idles 20 to 47 us at each boundary. So it is a fixed GPU-side cost per command buffer, not commit-to-start latency. On the M2, poll and waitfree can't gain anything, because the host is never late there, and the waitfree budget rule doesn't need to change for the M2. Only fewer buffers per step helps. onebuf removes X to Y, predicted at about 40 us on rf (2.9%) and 20 us on gbsa (2.3%). Next lever for both GPUs: under waitfree the per-step commit has no host wait behind it, so committing every k steps would drop the M2's Y to X' cost (gbsa about 46 us per step, about 5%) and the Ultra's 6 to 16 us residual mean at long leads.
- bgaps.py gained the 25 us lead table used above for the Ultra.
- 22:24Z. splitPass() for pme's roadmap item 2 (design 1, "a public MetalQueue::splitPass() wrapping the private endEncoding"). Branch cand/splitpass c515f3b34 on cand/poll: splitPass() takes the queue lock and ends the compute encoder, so the next kernel opens a new pass in the same command buffer; no commit. The pme probe got the same effect from getCommandBuffer(), which also opens an empty buffer when none is open. TestMetalCommandBatching gains testSplitPass: a slow kernel (1024 threads, 100000 LCG steps each) writes a buffer, splitPass(), a second kernel reads it; the test checks the commit count is unchanged and every value against the host LCG. 62 lines added, 1 removed (11 in MetalQueue, the rest the test). No production caller, so no timing change: the call sites (start of prepareInteractions under pme's flag, and around MetalCalcNonbondedForceKernel::execute) belong to the pme candidate. Built as t8 on the Studio and as ultra-m2/dispatch on the M2; t8-test.sh (one correctness hold) and m2split-test.sh (M2 lease) run the test once built.
- Two-constant model of a command buffer boundary, from the Ultra's p1 records and the M2 records above:
  - M3 Ultra: idle = max(0, L - lead), where L is about 110 us of commit-to-start latency and lead is how long before the previous buffer's GPU end the host committed the next one. Past a 110 us lead the boundary costs 0.5 us (median). The host can hide it by committing early: poll cuts the wake, waitfree runs steps ahead.
  - M2: idle is about 40 us (rf 39.5 to 47, gbsa 17.5 to 46.5 depending on the boundary) with the next buffer committed over 300 us ahead on 99.6% or more of boundaries. That is GPU-side cost per buffer that no host change hides; only fewer buffers per step remove it.
  - Both point the same way: fewer command buffers per step. Predicted M2 gain for onebuf (drops the X to Y boundary): rf about 40 us (2.9%), gbsa about 20 us (2.3%). Lead's order 22:27Z: screen onebuf cfc9547f3 against base on the M2 (gbsa, rf, pme, 2 x 15 s, my own tree ultra-m2/onebuf, m2check.sh under the M2 lease), then scope committing every k steps under waitfree after screen6, scope to the lead before building.
- 22:28Z. M2: ultra-m2/dispatch (cand/splitpass c515f3b34) built; m2split-test.sh runs TestMetalCommandBatching under the M2 lease. ultra-m2/onebuf synced (cfc9547f3); m2onebuf.sh builds it and runs `m2check.sh -r 2 -s 15 -t gbsa,rf,pme` (forces gate on its six tests, then single and mixed A/B against base).
- 22:27Z. M2: TestMetalCommandBatching on c515f3b34 passes, single and mixed (testSplitPass included; commits per step NoCutoff 0.01, PME 1.01). Studio t8 built 22:27Z; its correctness hold waits behind 32 tickets.
- 22:35Z. Scope draft, commit every k steps under waitfree (to send after screen6):
  - Only admitted systems qualify (no per-step host wait): gbsa everywhere, rf, pme and dhfr on the Ultra only. In computeInteractions() the commit becomes conditional: commit when the host waits this step (waitForCount, or getStepsSinceReorder() == 0), when k steps are open since the queue's last commit, or when every committed buffer has completed (the GPU would idle, so submit now; this also covers the start of a run and step(1) loops).
  - What already commits or syncs mid-batch, unchanged: every MetalArray upload and download (finish()): getState, setPositions and parameter changes, energy (reduceEnergy), reorderAtoms every 250 steps (downloads posq and velm, uploads them back), MonteCarloBarostat every frequency steps (energy), CustomIntegrator host-side globals; every MetalEvent::enqueue(): CCMA every 4 iterations, the PME stream sync (off by default), GayBerne, CustomManyParticle, ConstantPotential, the minimizer. Metal blocks commandBuffer() at 64 uncompleted buffers, so run-ahead grows to 64k steps; a getState then waits for all of it.
  - Tail: step(n) can return with up to k-1 steps unsubmitted while the GPU is busy; they go at the next commit or sync. Base already leaves the last half step unsubmitted, so this changes the amount, not the behavior. benchmark.py ends every timing with getState, so it doesn't see it.
  - k: cost per step is c/k (c the boundary constant) plus a bubble of about k x h per sync (h host encode time per step, two syncs per 250 steps: the reorder and the baseline wait after it). The "commit when idle" rule removes most of the bubble. Optimum about sqrt(250c/h): M2 gbsa c 46, h about 60, k about 14; Ultra c about 5 to 10 residual, h about 40, k about 6 to 8. So k = 8 everywhere, no device query beyond waitfree's admission.
  - Expected: M2 gbsa about 46 x 7/8 = 40 us per step, about 4.6%. Ultra gbsa and rf: the residual boundary cost under waitfree, which prof1 measures; the base records at long leads give gbsa means of 1.6 to 16 us and rf 0.6 to 3.9 us, so maybe 1 to 4% on gbsa and under 1% on rf. It may miss 3% on the Ultra.
  - Size: about 20 lines (a MetalQueue::isIdle() over pending.back()->status(), a steps-since-commit counter reset when the queue's commit count moves, the condition). TestMetalCommandBatching's PME bound drops to about 1/k where admitted.
- 22:34Z. Lead: a --quick gate doesn't count for merge; waitfree needs a full gate before it is a candidate, and its keep bar (3% or more over poll) is judged in a dedicated window. Stopped gate-waitfree.sh (pid 96037) before it reached gate --quick; its correctness hold (lease.sh pid 96044, TestMetalCommandBatching plus md100 on t5 and base) still runs into gate-waitfree.out. A full gate on t5 gets queued only if screen6 shows waitfree 3% or more over poll. k-step scope sent to the lead as drafted above, asking whether an M2-only gain can carry it.
- 22:44Z. M2 onebuf screen (checks/20260924T222907Z-cfc9547f3, m2check.sh -r 2 -s 15, gbsa, rf, pme): forces gate PASS on all 12 rows with rel|dF| identical to base, verdict PASS, nothing slower, footprint unchanged. Load average 2.5 to 9.1.

| M2, onebuf over base | single | mixed |
|---|---:|---:|
| gbsa | 1.005 (401.28 to 403.29 ns/day) | 1.008 |
| rf | 1.002 | 1.001 |
| pme | 0.997 | 1.002 |

  Predicted 2.3 to 2.9%. Removing the X to Y boundary did not remove its 20 to 40 us of measured idle, so the M2 model above (a fixed GPU cost per command buffer) is wrong, or the cost moves to the next boundary. That weakens the k-step M2 premise. Reported to the lead with an offer of a gpuprof buffers record of onebuf on the M2.
- Lead, after the k-step scope: an M2-only gain counts. Keep bar for any dispatch change: 3% or more on either chip, no regression over 0.5% on the other, full gate. Waitfree plus k-step is judged as one unit against poll on both chips. Build k-step now on waitfree a08243d4b, test on the M2 first. Scope changes: commit whatever is open when step(n) returns (step(1) loops then commit per step as today), and a test that runs step(n), idles 50 ms on the host, then getState, requiring all n steps done on the GPU and positions bitwise equal to a k=1 run under DeterministicForces. Report M2 numbers for waitfree+k against poll on gbsa, rf and pme.
- 22:40Z. M2: ultra-m2/poll (17fc67494) and ultra-m2/waitfree (a08243d4b) synced; built in sequence (build.out in each) as the A/B arms.
- 22:52Z. k-step screen. Branch screen/kstep 1ba144aea on cand/waitfree (+28/-5): MetalQueue::isIdle() (the newest committed buffer has completed, or none is pending), and computeInteractions() commits only on a wait step (waitForCount, or the step after a reorder), on the 8th step since the queue last committed, or when the GPU is idle; the step counter resets when anything else commits (downloads, events). No tail commit: benchmark.py times one step(n) then getState(energy=True), so work left open at the end of step(n) doesn't change its timing. M2: ultra-m2/kstep built by m2kstep.sh, then one m2check.sh session with poll (17fc67494), waitfree (a08243d4b) and kstep against base on gbsa, rf and pme, 2 x 15 s (kstep/check.out). rf and pme aren't waitfree-admitted on the M2, so there kstep only adds the condition. Studio: t9 building (t9-build.out), nothing queued there yet.
- Tail commit, for the candidate if the screen passes: openmmapi's Integrator::step(n) loops updateContextState, calcForcesAndEnergy and the integration kernel with no call at the end, so the platform can't see step(n) return. Plan: a committer thread per MetalQueue, started the first time a step defers its commit. It waits (outside the queue lock) on the newest committed buffer; when that completes with no newer commit and a buffer is open, it takes the queue lock and commits it. Every encoding path holds the queue lock around its encoder use, so the commit can't cut a kernel in half. A completion handler with try_lock would be lighter but can miss the commit when the host holds the lock at that moment and then returns from step(n).
- 23:14Z. M2 k-step screen (checks/20260924T225209Z-17fc67494, one m2check session of poll, waitfree and kstep against base, 2 x 15 s, gbsa, rf and pme). Forces gate PASS on all three arms. Round 1 ran with Spotlight (mds_stores up to 303% CPU) indexing the new trees, load 1.1 to 11.3; round 2 was quiet. Ratios against base, single/mixed:

| M2 against base | poll 17fc67494 | waitfree a08243d4b | kstep 1ba144aea |
|---|---|---|---|
| gbsa | 1.014 / 1.024 | 1.048 / 1.043 | 1.066 / 1.097 |
| rf | 1.015 / 1.020 | 1.024 / 1.019 | 1.020 / 1.018 |
| pme | 1.016 / 1.016 | 1.018 / 1.018 | 1.025 / 1.017 |

  Over poll, single/mixed: waitfree+k gbsa 1.051 / 1.072, rf 1.005 / 0.998, pme 1.009 / 1.001; waitfree alone gbsa 1.033 / 1.018. rf and pme aren't admitted on the M2, so their three arms run the same code and differ by noise. k-step adds 1.7% / 5.3% on gbsa over waitfree, near the 4.6% I predicted from the 46 us Y to X' boundary, so on the M2 the per-buffer cost is real once the host runs ahead, and onebuf's miss under a per-step wait is still unexplained. Poll gains 1.4 to 2.4% on the M2 too, so the host is late there after all on some steps.
  Footprint: gbsa peak footprint 65 MB on base, 108 MB with waitfree (+42, m2check GROWTH), 120 MB with k (+54). rf and pme unchanged. Likely the run-ahead: without the per-step wait the host commits up to Metal's 64 uncompleted buffers ahead, about 650 KB each.
- Review of the committer (adversarial reviewer, read only): no threading bug found. Every encoder and command buffer use is under the queue lock (executeKernelFlat, MetalFFT3D, MetalArray::copyTo, MetalEvent), no lost wakeup, the destructor joins, the 64-buffer block can't deadlock with the committer, waitForCount systems take the old path. Findings I acted on: the fixed 50 ms sleep could flake on a slow or shared GPU (now 50 ms then up to 10 s polling a new MetalQueue::isDrained()); the neighbor list's early reorder after step 25 reads a count whose age depends on host run-ahead, so the bitwise comparison now runs 25 steps; getLock() now documents that encoder users must hold it; the commit message notes that a queue shared with a linked context (CustomCVForce, ATMForce) gets the thread if any context qualifies. Not acted on: `pme <= 1.1` commits per step could fail on a GPU faster than its host, since idle commits count too (not seen on either chip yet).
- Reviewer finding outside this candidate: base 62e1e2e95 removed the commit after the forces, so a system without a neighbor list (NoCutoff, or cutoff under 3000 atoms) commits nothing inside step(n), and the GPU starts only at getState (TestMetalCommandBatching's NoCutoff 0.01 commits per step). The benchmark tests all have neighbor lists. Asked the lead whether to run the idle committer on every queue as its own candidate.
- Candidate cand/kstep a350c48df on waitfree, three commits: 700dd894e commit() waits for the oldest buffer when more than 8 are in flight (for the footprint); 0d7cda289 the idle-commit thread (MetalQueue::commitWhenIdle(), started from MetalNonbondedUtilities::initialize() when waitForCount is false; it waits outside the lock for the newest committed buffer, then commits the open one unless the host committed since) plus testWorkLeftOpenAfterStep (25 steps, 50 ms idle then up to 10 s, isDrained(), positions bitwise equal to a run synchronized every step, DeterministicForces); a350c48df k-step as screened. +116/-14 in src, +64/-7 in the test. Studio t10 rebuilding at a350c48df (t9 deleted). M2: kcand (9828f1832, the series without the in-flight cap) waits for the M2 lease behind infra's 7-test m2check, then TestMetalCommandBatching and poll vs kcand; m2kcap.sh then builds kcap (a350c48df), runs the test with the full output in kcap/test.out, and poll vs kcap.
- Studio: waitfree's correctness hold (96044) passed. TestMetalCommandBatching single and mixed pass on t5, and md100 (forces against Reference after 100 and 200 MD steps) on t5 matches base to every printed digit on gbsa, rf and pme. Cancelled screen5 (superseded by screen6, which has waitfree itself) and deleted t4 and the top-level probe build.
- 23:27Z. Studio: t10 built at a350c48df (23:23Z). Queued gate-kstep.sh (md100 on t10 in one --correctness hold, then the full gate.sh on t10, not --quick) and screen7 (ab.sh, poll t2 against waitfree+k t10, single and mixed, gbsa, rf, pme and amber20-dhfr, 2 x 15 s, estimate 10 min). About 58 tickets ahead. No drift.py or constraints.py: nothing in the series touches constraints or integration.
- M2: merged the two waiting jobs into one (kcap/m2kboth.sh) to save an M2 session. Once infra's 7-test m2check (cand, cand2, cand3) ends, it builds kcap (a350c48df), runs TestMetalCommandBatching on kcand (9828f1832, no in-flight cap) and kcap under the M2 lease with full output in <tree>/test.out, then one m2check of poll, kcand and kcap on gbsa, rf and pme. kcand against kcap in one session isolates the cap's effect on time and footprint.
- 23:28Z. M2 cleanup: deleted the kstep tree (screen done, results in checks/20260924T225209Z-17fc67494) and dispatch-prof's build, prefix, venv and src; its profile records stay in dispatch-prof/prof (28 MB).
- 23:34Z. Lead messages, received together. The regression bar is 1% (RULES line 11), not 0.5%. No wall-clock caps. The M2 has one owner, infra, with one queue, so I send every M2 build, check or profile as a request. Stop processes only by recorded pid. Get the onebuf M2 profile before any more k-step timing. Add a step(1) loop with 1 ms of host work, which k-step must not slow. Waitfree admission should follow nblist's maxBits. atomics is taking the force buffer out of hazard tracking. Design 3 is back as a paper plan only.
- onebuf is a dead end on the M2: gbsa 1.005 / 1.008, rf 1.002 / 1.001, pme 0.997 / 1.002 over base, against a predicted 2.3 to 2.9% (22:44Z entry). Dropping the X to Y boundary didn't remove its 20 to 40 us, so either the per-buffer cost model is wrong or the cost moved to the next boundary. The M2 profile of base and onebuf decides between them.
- M2: stopped my m2kboth.sh (pid 15010) before it built anything and removed its script. Sent infra three requests. A: gpuprof buffers of prof/base 188840b78 and prof/onebuf 21dd28601 (new branch, onebuf cfc9547f3 plus the same hooks, cherry-picked cleanly) on rf and gbsa single. B: TestMetalCommandBatching on kcand and kcap. C, held until A reads: m2check poll, kcand, kcap on gbsa, rf and pme, and hostwork.py poll vs kcap.
- Studio: stopped gate-kstep.sh (2031) so the full gate wouldn't queue at the back only after md100. md100 keeps its ticket (2090), and the t10 full gate has its own (gate.sh, 61357). Queued hostwork1 (75486): hostwork.py, 2000 x (step(1) plus 1 ms of busy host work) and a getState, on poll t2 and waitfree+k t10, single and mixed, gbsa, rf, pme and amber20-dhfr, 3 rounds in one timing hold, about 9 min. Kept screen6, prof1, t8-test and the t2 gate. screen7 and hostwork1 are about 6 h out, and I'll stop them if the M2 profile says the gap moves.
- Admission already follows maxBits. a08243d4b moved the MAX_BITS_FOR_PAIRS choice out of createKernelsForGroups() into getMaxBitsForPairs(), which sets both the kernel define and the admission bound. So nblist's MAX_BITS 0 edit belongs there, and it will conflict with that block at merge. With maxBits 0, rf and pme need about 36 MB of tiles, still over the M2's 22 MB budget.
- For atomics' untracked force buffer. Apple's docs say an intrapass barrier orders only commands in the same pass, while a fence orders passes on one queue, including passes in other command buffers, as long as the producer is committed first. Every variant (base, poll, onebuf, waitfree) commits in computeInteractions() between nonbonded, the last force writer, and reduceForces, the first reader. copyTo() is a blit pass. k-step puts up to 8 steps in one pass, so the next step's clear follows this step's readers inside the pass, and the idle commit can end a pass between any two kernels. Offered a queue-owned MTLFence (each new encoder waits on it, each endEncoding updates it) if atomics needs one. The count wait reads the pinned count buffer after an encoded event signal, and download() finishes the queue first, so neither relies on tracking.
- Tail commit stays a thread rather than a completion handler, as the lead suggested checking. The handler would need the queue lock. The host holds that lock while encoding and during the in-flight cap's wait. Blocking on it from Metal's callback queue risks deadlock, and skipping loses the commit when step(n) returns right after.
- To do: findBlocks' early exit launches every threadgroup with full threadgroup memory on non-rebuild steps. That costs 27 us on apoa1 and 6 us on pme, about 1.5% of an apoa1pme step (nblist's scan). It's a target for an indirect or zero-threadgroup skip.

### Design 3 paper plan (23:58Z). Nothing is built.

The dispatch inventory comes from a read-only research pass over the profiler's base 6df2b8bcb counters records (ultra-profiler/p1, 3,492 to 11,891 steps per test) and the source.
- Every test runs the same shape each step: COM (2 dispatches), one autoclear, the neighbor-list chain (6 dispatches plus a blit with the short-list sort, or 10 with the bucket sort), the test's own force kernels, then bonded, then nonbonded, then the integrator (5 or 7).
- Rebuild and non-rebuild steps issue the same dispatches.
- Mean dispatches per step: gbsa 20.25, rf 18.25, apoa1rf 22.25, pme and dhfr 27.25, apoa1pme 31.26, cellulose 31.30.

Accumulate-only writers of longForceBuffer (atomic adds only, no plain access to it in the kernel):
- computeBondedForces (BondedUtilities.cpp:161-163).
- computeNonbonded (nonbonded.metal:221-231, 435-442, 491-496).
- computeGBSAForce1 (gbsaObc.cc:518-527). It is also accumulate-only on bornForce.
- computeBornSum is accumulate-only on bornSum.

Not accumulate-only:
- gridInterpolateForce does a plain `+=` on longForceBuffer (pme.cc:351-353). Its atomic branch (pme.cc:347-349) compiles only with USE_PME_STREAM, and DisablePmeStream defaults to true (MetalPlatform.cpp:137).
- energyBuffer has no accumulate class at all. computeBondedForces, computeGBSAForce1 and reduceBornForce each do a plain `energyBuffer[GLOBAL_ID] +=` (BondedUtilities.cpp:123, gbsaObc.cc:744, gbsaObcReductions.cc:57), even on force-only steps.
- The only reader of longForceBuffer in the step is integrateLangevinMiddlePart1.

True edges:
- The clear goes before every writer.
- The neighbor-list chain goes before nonbonded and the GBSA pair kernels.
- The Born chain: computeBornSum, reduceBornSum, computeGBSAForce1, reduceBornForce, then computeNonbonded.
- The PME chain: atom sort, spread, finishSpread, FFT, convolution, FFT, then interpolate.
- All force writers go before Part1, and the integrator chain stays in order.
- Each step's readers go before the next step's clear.

False edges that serial order enforces today:
- Bonded against everything between the clear and Part1: the neighbor-list chain and nonbonded in every test, the GBSA chain in gbsa, the PME chain in the PME tests.
- The neighbor-list chain against the PME chain.
- In gbsa, bonded stays tied to computeGBSAForce1 and reduceBornForce by the energyBuffer writes, so gbsa gains nothing from any version of this.

Settle first: does the serial encoder overlap dispatches that share no tracked writable buffer? Apple's header says serial dispatches "are executed in dispatched order" (MTLCommandBuffer.h:228-229). Barriers on a serial encoder are "allowed, but ignored" (MTLComputeCommandEncoder.h:317, 324). The evidence points both ways:
- Profiler block 1 found one encoder per dispatch 4 to 6% faster on apoa1pme, cellulose and stmv, which says passes overlap under tracking and the serial encoder doesn't.
- atomics' words gain shows up in unprofiled windows too, which would say the opposite, unless words' kernels are simply cheaper there.

Experiment 0 decides it. It's a standalone C++ microbenchmark on metal-cpp, no OpenMM, about 150 lines, in one timing hold under 2 minutes on each chip (the M2 through infra).
- Kernel: one threadgroup of 32 threads, an FMA chain of about 200 us, then one relaxed atomic add into its buffer. Two copies fit side by side on 10 or 60 cores.
- Each case is one command buffer. Time is GPUEndTime minus GPUStartTime, median of 50. Two kernels under 1.2x one kernel count as overlap; over 1.8x count as serial.
- Cases:
  - S1: serial encoder, A writes X, B writes Y.
  - S2: A and B write the same tracked X.
  - S3: B writes X2, where X and X2 are two newBuffer(pointer, length, options, deallocator) wrappers of one page-aligned allocation.
  - S4: X untracked.
  - S5: S1 with X also bound to B at an index B's function doesn't declare.
  - P1 to P3: S1 to S3 with A and B in separate encoders of one command buffer.
  - C1: concurrent encoder, A and B both write X.
  - C2: C1 with memoryBarrier(resources: X) between them.
- Ordering checks, not timed. A spins, then writes a sentinel through X2. A 1-thread join dispatch binds X and X2. D reads through X and must see the sentinel 100 times out of 100. Repeat with S4 plus a barrier, to see whether the barrier really is ignored.

Designs by outcome:
- D3a, if S1 and S3 overlap and the join orders: aliasing inside the serial encoder.
  - Allocate longForceBuffer from page-aligned shared memory and wrap it twice: F, which is today's buffer, and Fb. computeBondedForces binds Fb, and everything else binds F.
  - Tracking then lets bonded run beside the neighbor-list chain, the PME chain and nonbonded, and keeps every true edge. The clear gets Fb as a size-0 autoclear entry, so bonded waits for it.
  - A 1-thread join kernel binds F and Fb after nonbonded, so Part1 waits for both writers.
  - No barriers, no fences, no concurrent encoder. Tracking also keeps working across k-step's and the idle committer's arbitrary buffer splits.
  - Cost is one dependent dispatch per step, about 1.9 us (lab 008).
- D3b, if S1 is serial but P1 and P3 overlap: the same aliasing, with bonded in its own compute encoder. That's 2 more encoder boundaries per step, priced by P against S.
- D3c, if only C1 overlaps: the concurrent encoder as the design doc wrote it, with the barriers below.

Admission for D3a and D3b:
- Bonded on Fb races any plain access to F between the clear and the join. So interpolate must switch to its atomic branch through a Metal-only define that doesn't also move PME to its own queue.
- Aliasing applies only when every force in the System is on a list whose kernels were read as accumulate-only: the bonded forces, NonbondedForce, GBSAOBCForce and CMMotionRemover. Anything else keeps today's single buffer.
- energyBuffer stays one tracked buffer, so on energy steps tracking orders bonded as it does today.
- Admit per device, only where bonded is a large share of the step. On 10 cores, nonbonded alone fills the M2.

Barriers for D3c, per step on the concurrent encoder:
- gbsa: 18 of 20 dispatches (all but bonded and one COM dispatch sit on a chain).
- rf: 16 of 18.
- apoa1rf: 20 of 22.
- pme and dhfr: about 22 of 27.
- apoa1pme and cellulose: about 26 of 31.

The gbsa cost is measured, not modeled. auto lost 8.1% on gbsa with barriers on 74% of dispatches (screen2, 21:10Z), about 23 us over 15 barriers, or 1.6 us each.
- gbsa: D3c would put barriers on 18 dispatches, about 29 us or 10% of the step, to hide at most bonded's 26 us. So gbsa stays serial under every variant.
- rf: 16 barriers cost about 26 us, against bonded's 27 us.
- D3a costs gbsa nothing, since gbsa isn't admitted.

Expected gain. This is bounded by the bonded span the overlap hides, and bonded competes for the same cores.
- Base spans from probe 1a, counters mode: apoa1rf 176 us of 818 (21%), apoa1pme 253 of 1242 (20%), cellulose 956 of 4476 (21%).
- With chunked bonded d8ab45b2b at atomics' estimated 5x less: about 35, 50 and 190 us, roughly 4% each. D3a's ceiling after chunking is 3 to 4% on those three and 0 to 1% on rf, pme and dhfr.
- D3c after chunking: cellulose 190 minus 26 x 1.6 is about 150 us, or 3% at best. apoa1rf and apoa1pme come out near 0. So D3c is dead once chunking lands.

Build gate:
- The lead's gate: census 1b (ticket 87308) shows bonded with d8ab45b2b at 5% or more of the step on apoa1rf, apoa1pme or cellulose.
- I'd add that experiment 0 shows S3 or P3 overlapping.

Correctness plan once built:
- A bitwise force diff against serial Metal on rf, gbsa and apoa1rf. Integer adds commute, so these must match exactly. Add apoa1pme and cellulose for the atomic interpolate.
- The bitwise run in TestMetalCommandBatching.
- Forces against Reference after 100 MD steps.
- The full gate.

Size: D3a is about 60 lines (aliased allocation, the Fb binding, the join kernel, admission) plus the interpolate define.

Relation to atomics' direct fix, an untracked force buffer plus a fence: it depends on the same experiment 0 (case S4). An untracked F needs a fence at every pass boundary between the clear, the writers and the readers. It also needs the reader-to-next-clear edge. Under k-step, that edge falls inside one pass, where only a barrier works, and a serial encoder ignores barriers. Aliasing keeps tracking and needs neither.

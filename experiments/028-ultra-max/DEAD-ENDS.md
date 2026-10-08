# 028 dead ends

Ideas that experiment 028 tried or priced on the M3 Ultra and the M2, and why each died.

The Source column names the experiment log, the review or the design study the row came from. Experiment logs and the run ledger are in this repository's history at commit 31c615ad (`experiments/028-ultra-max/lanes/` and `LEDGER.md` section 3); the design study is `research/2026-09-25-metal-native-design.md` and the playbook is `research/2026-09-25-metal-native-playbook.md`.

| Area | Idea | Numbers | Why it died | Source |
|---|---|---|---|---|
| dispatch | onebuf cfc9547f3 on the M2 (22:29Z check, forces PASS) | gbsa 1.005/1.008, rf 1.002/1.001, pme 0.997/1.002 (single/mixed) against a predicted 2.3-2.9% | Dropping the X-to-Y buffer did not remove its 20-40 us idle; the fixed-cost-per-buffer M2 model is wrong or the gap moves. k-step M2 premise (46 us/step gbsa) in doubt until a gpuprof buffers record explains it | lanes/dispatch.md |
| nonbonded | Stage block Y positions and index in threadgroup memory (tgp), plus parameters (tgpa) | screen 1 round 1, single, 15 s, host clock, load about 10 cores: 0.987 to 1.003 | Shuffles are not the cost on the Ultra | lanes/nonbonded.md 21:18Z |
| nonbonded | Screening TGF, TGP, TGA one at a time | expected < 1% each, ceiling 3 to 5% on rf, apoa1rf | Screen one bundle instead, counters first | review |
| nonbonded | Owning NB_TILES | n/a | numTilesInBatch only affects findBlocks; handed to nblist | review |
| atomics | Native 64-bit atomic add | compile failure on Apple9 | Not in MSL 4.1 on any family | lanes/atomics.md 19:30Z |
| atomics | Latency hiding: batched low words, deferred carry | microbench all equal 1480 us; with FMAs 2596/2490 vs 2630; forcetime defer carry 0.979 to 1.003 | Op count, not latency, is the limit | lanes/atomics.md 19:30Z, 19:55Z |
| atomics | k_float: device float atomics for forces | M2 190.8 ms vs Ultra 0.34 ms (lab 004) | CAS loop on M2, order-dependent results; words reaches the same op count deterministically | review; design doc |
| atomics | Extend force words to PME interpolation | n/a | PME stream is off, so that path has no atomics; with it on it races the fold | review |
| atomics | Force words as first built (nonbonded only, no gating by size) | apoa1rf 1.114, rf 1.069, apoa1pme 1.005, pme 0.992, gbsa 0.983 (forcetime, single, CLT tree, load 8.2 to 18.4) | Fails the 1% rule on gbsa (fold dispatch); superseded by 4be61f9b6 | lanes/atomics.md 21:23Z |
| atomics | Sorting bonded terms by lowest atom before chunking | chunkstat 64 per chunk, original vs sorted: apoa1rf 5.5x/5.6x, apoa1pme 4.8x/4.7x, cellulose 3.4x/4.3x, pme 3.3x/3.4x | Helps only cellulose; 45bf92869 keeps the original order | lanes/atomics.md 22:05Z |
| atomics | Words for bonded | n/a | Throwaway if chunked bonded lands (design: chunking cuts adds 8 to 14x vs words' 2 to 1; measured chunking is 3.3 to 5.5x per force, 22:05Z) | design doc section 3 |
| atomics | Fast-math or algebraic torsions | arithmetic 1 to 3 us/step | Not the bottleneck until atomics are gone | design doc bonded rejected |
| atomics | Skip intra-water PME exclusion corrections for rigid water (64k of 218,698 pairs) | n/a | getState forces change; gate fails | design doc bonded rejected |
| nblist | Hardware ray tracing for neighbor search | n/a | Intersection functions run shader code; loses to cell lists at 1 nm cutoff; periodic ghosts; no RT on M1/M2 | design doc; playbook |
| nblist | simdgroup_matrix for distance masks | about 290 cycles vs 32 to 64 FMA cycles | Slower, and r2 cancellation error about 5e-5 in LJ forces exceeds the gate | design doc |
| nblist | Looser rebuild trigger (d1+d2 > padding) | list lives 2 to 3% longer | Too small | design doc |
| nblist | Check overflow one step late | n/a | One step silently loses interactions (nonbonded.metal:239-241) | design doc |
| nblist | Cell grid replacing the size sort | n/a | At dhfr size the 27-cell stencil covers the box; revisit only if NB_TIME says otherwise | design doc |
| nblist | Persistent-grid kernels with inter-threadgroup waits (decoupled look-back) | n/a | No Apple forward-progress guarantee; 9074c38f1 is the local example | design doc; playbook |
| nonbonded | simdgroup_matrix pair distances | r2 error about 5.4e-7 absolute, 5e-5 in LJ forces | Above the 2.5e-5 gate; distance math is 5 to 6 of 50 to 100 ops | design doc |
| nonbonded | FP16 GB or LJ math | n/a | 11-bit mantissa far outside the gate | design doc |
| nonbonded | Privatize bornSum or GB forces in threadgroup memory | flush 1.8M ops vs 300k; GB forces 40 KB > 32 KB | gbsa is not atomic-bound (1.051) | design doc |
| nonbonded | Fuse reduceBornSum/reduceBornForce with last-arriver counters | saves 2 dispatches of about 4 us (about 3% of gbsa) | +2 int atomics per lane per tile; too little for the risk | design doc |
| nonbonded | Store per-pair chain-rule terms | about 20 MB/step, about 50 us | More than the math saved | design doc |
| nonbonded | Function constants instead of #defines | n/a | Identical codegen; only helps compile time | design doc; playbook |
| nonbonded | Tensor ops or Neural Accelerators for pair tiles or FFT | Rigel 1.05 to 1.21x over simdgroup_matrix at fp16 | Pair tiles are gather and transcendental bound; TF32 too imprecise | playbook |
| nonbonded | MSL 4.1 threadgroup float atomics in pair kernels | n/a | Review keeps 4.1 out | design doc |
| pme | VkFFT knobs (useLUT -1, coalescedMemory 32 and 128, aimThreads 256) | float build, 2x15 s, single, load 3 to 18, apoa1pme/pme: 0.996/0.998, 1.001/1.004, 0.999/1.000, 1.000/1.001 | Flat | lanes/pme.md 19:50Z |
| pme | Tiled spread, one atom per thread, MSL 4.1 atomic_float or CAS (tiled, tiled41) | M2 vs fixed: tiled 0.798/0.801/0.799, tiled41 0.784/0.802/0.799 (pme/apoa1pme/apoa1ljpme). Ultra vs lab: 0.829/0.774/0.794; vs ultra-base 0.954/0.921/1.090 | Threadgroup atomics are no cheaper than device atomics; 28 KB tile allows one 256-thread group per core | lanes/pme.md 21:03Z, 21:42Z |
| pme | Tiled spread, one (atom, z) pair per thread (ti256, ti1024) | M2 vs fixed: ti256 pme 0.827, apoa1pme 0.840; ti1024 0.867, 0.886. Ultra vs lab: ti1024 apoa1pme 0.997, pme 0.998, apoa1ljpme 0.971 | Ties at best on the Ultra; needs MSL 4.1 or CAS | lanes/pme.md 21:38Z, 21:42Z |
| pme | Int-tile spread with threadgroup atomics (native roadmap item 8) | tiled41 vs float on the Ultra 0.774/0.829/0.794; ti1024 0.997/0.998/0.971 | Killed by its own rule without a build: threadgroup atomics do not beat the spread's device atomics on Apple9 | lanes/pme.md 22:10Z |
| pme | PME as its own tracked pass on the M2 (split, splitb) | M2, single, 2x15 s, load 1.6 to 2.5, vs lab: pme 1.000, apoa1pme 1.000; split plus skip interpolation 1.043/1.048 equals skip alone 1.041/1.048 | Nothing to overlap on 10 cores; costs nothing either. The M3 Ultra arms (splitvar.sh) are still queued | lanes/pme.md 22:10Z |
| pme | pmeForce array plus fold (PME_LAB_PMEFORCE) on the M2 | M2, single, 2x15 s: pmef 0.989 pme, 0.995 apoa1pme; pmefb the same; forces bitwise identical | The extra dispatch and pass boundaries cost about 1% on pme; must stay off on the M2. Ultra not measured | lanes/pme.md 22:15Z |
| pme | 256-thread spread groups, one work item per thread (b256m5) | Ultra vs lab: apoa1pme 0.998, pme 0.998, apoa1ljpme 1.007 | Flat | lanes/pme.md 21:42Z |
| pme | PME stream (MetalDisablePmeStream=false) | Ultra vs lab: apoa1pme 0.861, pme 0.659, apoa1ljpme 0.908. M2: pme 0.884, apoa1pme 0.959, apoa1ljpme 0.968 | Extra commits per step and 64-bit force atomics in the gather cost more than the overlap | lanes/pme.md 21:42Z |
| pme | Float atomics on Apple8 | M2 float/fixed: pme 0.958/0.955, apoa1pme 0.970/0.971, apoa1ljpme 0.935 | Loses to fixed point on the M2; keyed to Apple9 | lanes/pme.md |
| pme | Change PME grid size or alpha | n/a | Reference uses the same grid; gate fails | lanes/pme.md; design doc |
| pme | Parity-partition atomic-free spread (8 passes over 5-cell blocks) | upper bound from plain probe: apoa1pme reciprocal 0.20 to 0.23 ms vs 0.43 to 0.46 | Brings back a per-step binning pass, serial passes; not expected to pay, not built | lanes/pme.md 21:42Z |
| pme | Hand MSL FFT, MPSGraph FFT, simdgroup_matrix DFT, MLX FFT | MPSGraph 4 to 7x slower; VkFFT at OpenCL parity | At most about 4% of apoa1pme | design doc |
| pme | Gather spreading | 19x slower Ultra, 34x M2 (lab 011) | Slower | design doc |
| pme | Fused spread plus FFT, or inverse FFT plus interpolation | n/a | Needs a device-wide barrier inside a kernel | design doc |
| pme | Concurrent encoder with memoryBarrier(resources:) for PME | n/a | Undocumented barrier scope; separate tracked passes instead | design doc |
| pme | ICBs for the PME chain; imageblocks for spread | idle gap 0.7% apoa1pme | Host not on the critical path; same 32 KB limit | design doc |
| pme | SIMD-cooperative gridInterpolateForce | kernel 43 us (about 3% of apoa1pme) | 2x is about 1.5% of step | design doc (pme experiment still lists a 5-lane gather as planned) |
| pme | Further PME atom sort work | n/a | Removed on Metal by 17929e631 | design doc |
| dispatch | Concurrent encoder with auto hazard barriers | gbsa round 1, host clock, load 3.8 to 6.6: 1142.92 vs 1244.21 ns/day (0.919); 74% of dispatches needed a barrier | Forces writers cannot overlap; stopped at 21:30Z | lanes/dispatch.md |
| dispatch | Concurrent encoder with no barriers as a ceiling | gbsa rel\|dF\| 0.85, rf 0.83, pme page fault | Wrong physics, cannot be timed | lanes/dispatch.md 19:58Z |
| dispatch | Accumulate hazard class for the concurrent encoder | n/a | Moot once the concurrent encoder stopped; revived 23:30Z as Design 3 after probe 1a, pending census 1b | design-review item 18 |
| dispatch | Early commit (DISPATCH_EARLY) | gbsa round 1: early 1175.69 (0.945, 3 commits/step), autoearly 1136.75 (0.914) | Extra buffer costs about 16 us per gbsa step; late commits are only 1.4 us gbsa, 3.5 us rf | lanes/dispatch.md; review |
| dispatch | Lazy commit in wait() for all events | n/a | Would delay the PME and download queues; only the count event uses signal-without-commit | lanes/dispatch.md 21:12Z |
| dispatch | 50 us spin-then-block wait (lab 024) | gave nothing | Poll chosen instead | review |
| dispatch | One serial encoder per kernel (perenc, screen4) | profiler split mode apoa1pme 1.003 | Plain split gives nothing; screen cancelled 21:47Z | lanes/dispatch.md 21:47Z; lanes/profiler.md |
| dispatch | Metal 4 port | 2.16 vs 1.88 us per dependent dispatch (lab 008) | Slower dispatch, no hazard tracking | design doc |
| dispatch | ICBs recorded once and replayed | host encode 0.112 us/dispatch | Host is hidden by run-ahead; no setBytes; concurrent only | design doc; api-check item 9 |
| dispatch | Persistent megakernel with a grid-wide barrier | n/a | No inter-threadgroup forward progress | design doc |
| dispatch | Poison-and-replay overflow; all-pairs fallback | n/a | Breaks the n-steps contract; gbsaObc.cc has no no-list path | design doc |
| dispatch | Replacing finish()'s waitUntilCompleted | 90 to 110 us wake | Only matters for getState and CustomIntegrator syncs | design doc |
| dispatch | Second MTLCommandQueue for PME in the dispatch experiment | separate queues about 2x concurrency (Turner) | Left to pme's stream flag, which died | design doc |
| dispatch | Metal 4 encoders, ICBs, indirect dispatch for constraints | n/a | No CCMA host round trips in benchmark.py (lab 022) | design doc |
| profiler | Plain one-encoder-per-dispatch split for encoder overlap ("5% serial barrier") | split: apoa1pme 1.003, pme 0.998, gbsa 1.040, rf 1.027 | The counters-mode speedup comes with sample attachments | lanes/profiler.md |
| profiler | UseBlockingSync=false as a host-wait lever | not timed | The property is never read | lanes/profiler.md |
| mixed | c5 0cad63bc2: LangevinMiddle kick in real | mixed gbsa +1.7%, pme +0.9%; stack 1.119/1.165 vs 1.101/1.155 | Fails TestMetalMixedPrecisionMixed at 1e-12; CUDA mixed does the kick in double | lanes/mixed.md |
| mixed | c1 one-shot SETTLE velocity solve in float directions | bond-relative velocity up to 2.3e-6 nm/ps (old 6e-15) | Replaced by the two-pass fix (9.5e-13) | lanes/mixed.md |
| mixed | c3 float warm start to the full tolerance | about 15 sweeps below float resolution | Now stops at 1e-7*d2 and 1e-5 | lanes/mixed.md |
| mixed | c3 SHAKE warm start (933483458) at all | Screen A gbsa +2.2%, pme +0.1%; screenRF rf +0.4%; SHAKE error at 1e-8 slightly worse than base (M2 2.32e-8 vs 2.26e-8; Ultra 2.57e-8 vs 2.25e-8 on gbsa) | Gains 3% nowhere; dropped 22:11Z with its 104 lines; g2 drops it. Why it costs SHAKE accuracy is unexplained | lanes/mixed.md 22:11Z, 22:19Z |
| mixed | Ungated common-code mixed changes | n/a | Applied to CUDA, OpenCL, HIP untimed; replaced by 6c97bd5de | lanes/mixed.md |
| mixed | screen1 with unwrapped ab.sh (7 tests x 3 configs requeued per round and test) | 14 queue passes; killed 20:45Z | Wrap the screen in one lease.sh | lanes/mixed.md |
| mixed | Rebuilding trees while syncs run | stale plugin, BUILT looked current | Staleness check cannot catch it | lanes/mixed.md |
| mixed | Raw (hi, lo) df64 storage | < 1% | Every host download needs conversion; fused kernel removes most conversions | review; design doc |
| mixed | Quad-cooperative SETTLE | < 10 us/step after c4 | SETTLE is mostly sequential | design doc |
| workloads | OpenCL per-allocation cap as a 2x workload | 14.58 GiB cap, about 130M atoms at 120 B/atom | Beyond what the 77.76 GiB working set holds on either platform | lanes/workloads.md |
| workloads | wl-ab.sh first launch | n/a | pgrep regex bug; relaunched 19:53Z | lanes/workloads.md |
| plugins | 027 port.sh tree | n/a | Rename bugs; regenerated | lanes/plugins.md |
| plugins | First AMOEBA timing 20:29Z | see scoreboard | Load 15 to 45 in round 2; redo | lanes/plugins.md |
| infra | ab.sh 20 s fairness pause | n/a | Superseded by FIFO lease | lanes/infra.md |
| infra | Timing holds that wait for zero builds | 15 waiters, no holder at 20:45Z | Builds overlapped without a gap; lease.sh no longer waits | lanes/infra.md |
| infra | Full ctest in one hold | 1177 s for 134 tests | Near the 1200 s cap; split into parts of 30 | lanes/infra.md |
| infra | ultra-base built with the CLT SDK | n/a | Toolchain rule; rebuilt 20:35Z | lanes/infra.md |
| m2 | OPENMM_PLUGIN_DIR shortcut for fast M2 checks | n/a | Exact only for diffs confined to plugin libs; replaced by per-candidate trees | lanes/m2.md |
| research | MLX fast-synch GPU/CPU spin fence | n/a | Undocumented scope, open wedge bug (mlx #3142); lab probe only | playbook |
| nblist | Wrap rows (0669fddab), alone or on batch 4 | NB_TIME 23:12Z, findBlocks per rebuild: alone pme 280.7 to 245.5 (-13%), apoa1pme 619.9 to 827.9 (+34%), apoa1ljpme +7%; at batch 4 pme 160.6 vs 164.1 with nonbonded +4% | Lengthens the longest row on apoa1; adds nothing at batch 4. Research's emulator had predicted wrap at batch 4 fastest (rf 70 vs 93 us longest SIMD group); the miss is with research | lanes/nblist.md |
| nblist | findBlocks prefetch, threadgroup 64, pair buffer 128 | prefetch 2-3% slower everywhere; threadgroup 64 no change; pair buffer +7% pme, +4% apoa1ljpme, -6% apoa1pme | No gain, or a spread that fails the 1% rule | lanes/nblist.md 23:12Z |
| nblist | Bucket-sort commits a96b568fa (SIMD-group bucket add) and 411a9f19a (SIMD prefix scan) | t4 stack failed gate --quick on pme and apoa1, rel\|dF\| 13-32 | Broken in the long sort path; under the 3% bar once nosort lands. Moved to ultra/nblist-wip | lanes/nblist.md 22:55Z |
| profiler, pme | More threadgroups: grid cap 12 to 24 blocks per core (tbpc24); nonbonded launch shape 6x256 | whole-step ratios within 1.2% of prof on gbsa, rf, pme, apoa1pme | The grid cap limits no kernel end to end; a faster PME spread must change the work per thread, not the group count | lanes/profiler.md, lanes/pme.md 23:19Z |

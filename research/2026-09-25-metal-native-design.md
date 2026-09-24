# Native Metal design study, experiment 028

Written 2026-09-24 around 21:20Z by a six-agent read-only study (five area designers and one synthesis, Opus 5.5 at high effort, no GPU time). Base commit 6df2b8bcb on the M3 Ultra, with the M2 as the must-not-regress chip. The synthesis comes first, then each area's designs and rejected ideas.

## Synthesis and roadmap

Synthesis of the 028 native-Metal design study (read-only)

The five studies land on three Apple facts that the shared kernels ignore:
- Apple GPUs have no 64-bit atomic add, so the number of atomic ops decides what every force write costs.
- Metal's tracked hazards let independent compute passes overlap on one queue. An in-order OpenCL queue cannot express that.
- Unified memory and indirect dispatch let the GPU own decisions the host owns today: list capacity, whether to rebuild, and which kernels run.

I made three changes to the design set:
- The GPU-gated rebuild chain appears twice, as nblist design 2 and dispatch phase B. nblist owns it.
- The fused LangevinMiddle kernel also appears twice, as dispatch design 2 and bonded-area design 2. mixed owns it.
- Dispatch design 3, the concurrent encoder with an accumulate class, now sits behind pme design 1. Splitting chains into separate tracked passes gives the same overlap, and it doesn't depend on the undocumented scope of memoryBarrier(resources:).

1. Tonight

The lease FIFO is 15 or more deep and lanes cap near 23:50Z, so each lane realistically has one 20-minute slot left. Freeze-forecast items keep priority. Each probe below rides inside a lane's existing bundle and is compiled in, not env-gated, unless it is a timing-only probe with wrong physics. In priority order:

a. atomics. Per-kernel atomic floor, with no new code. Apply the lane's existing "1 atomic (wrong)" and "plain RMW (wrong)" variants of the common.metal atomicAdd to the profiler's counters-mode tree. Run base, 1-atomic and plain on apoa1rf, apoa1pme, cellulose and rf, at low load (the 19:55Z probe ran at load 3 to 3.9).
- Build the chunked bonded kernel if computeBondedForces falls 50% or more under plain RMW on apoa1rf and cellulose. Kill it below 30%.
- x-resident tiles and super-cluster go ahead if computeNonbonded falls 25% or more under 1-atomic on apoa1rf. They are dead below 10%.
- This run is item 5.

b. pme. The split-pass probe, about 25 lines, merged into ticket 41058, whose stream arm is already arm C.
- Arms: A is serial with interpolation skipped, B is split-pass with interpolation skipped, C is MetalDisablePmeStream=false.
- Tests: pme, apoa1pme and apoa1ljpme, 2 x 15 s, plus one buffers-mode timestamp pass of B.
- Kill if B/A is below 1.03 on both pme and apoa1pme, or if the timestamps show pass P starting after D ends.
- If C beats B, the fold design moves to the second queue.
- Read ticket 41058's PLAIN and NOWRITE arms in the same sitting. They decide the int-tile spread with no build: kill it if PLAIN is less than 35% faster than float or tiled41 is below 0.9x on the Ultra.

c. dispatch. The wait-free probe:
- Set maxTiles = totalTiles and maxSinglePairs = 20 x numAtoms.
- Remove the prepareInteractions enqueue and the computeInteractions wait.
- Do one commit plus encodeSignalEvent per step, and poll N-2 before encoding.
- Run gbsa, rf and pme as the control. The overflow count at teardown must be 0.
- Keep it if the idle gap falls 15 us or more on gbsa and 30 us or more on rf, and wall time falls 5% or more on both. Kill it if the gap falls less than 8 us. That would mean the gap is not the wait, and the poll wait is the right fix.

d. nonbonded. x-resident tile runs, 40 to 60 lines in nonbonded.metal, compiled in.
- Counters A/B of computeNonbonded on apoa1rf and rf, plus forces.py single and TestMetalHippoNonbondedForce.
- Keep at 12% or more on apoa1rf, kill under 5%.
- Measure it on base tonight. It gets rebased onto force words later.

e. research, which is idle. GBSA kill test, 15 lines: a Metal-only computeGBSAForce1 with one fast rsqrt and a per-atom 1/B in place of the precise sqrt and three reciprocals.
- Counters on gbsa, base against the patch.
- Continue to stage A at 10% or more. Under 5%, the family narrows to the Apple9 launch-shape change.
- Hand it to nonbonded afterwards.

f. nblist. Zero code: add NB_PAD=220 arms on rf and apoa1pme to job2 on t3. Read three numbers:
- findBlocks per rebuild, which gives k.
- The rebuild fraction, which gives r_out.
- The computeNonbonded delta.

Kill the dual list if C x k x r_out > 0.6 x F_now on either test. This slot must not displace sort2, computeRange or the tiles rule.

g. profiler. No GPU needed for the first part:
- From p1, pull computeNonbonded per test (x-resident needs that baseline) and the Part1-to-Part3 encoder union on rf and gbsa single.
- If a slot frees up, run the same union in mixed on rf and pme.
- The fused integrator dies if the single rf union is under 15 us and the mixed pme union is under 120 us.

mixed and plugins get nothing new tonight. mixed's c-bundle is the prerequisite for its native work. plugins should run the HIPPO ctest on anything that touches nonbonded.metal.

2. Multi-day roadmap, by expected whole-step gain per engineering day

1. x-resident tile runs, owned by nonbonded, about 0.3 day.
   - Gain: apoa1rf 1.08 to 1.20x, rf 1.04 to 1.07x, the large PME tests 1.04 to 1.10x, gbsa 1.00x.
   - Depends on item 1a showing computeNonbonded is op-bound, and on the TG-variant bundle being settled first because they edit the same atomicAdd sites.
   - Then rebase force words on top: words makes each add cheaper, this removes adds.
   - Apple8 runs the same kernel. With 800 SIMD groups the chunks are 6x longer, so it should help the M2 more. M2 memory: none.

2. PME as its own tracked pass, owned by pme with a splitPass() API from dispatch, about 0.5 day.
   - Gain: pme and dhfr 1.05 to 1.17x, apoa1pme 1.07 to 1.15x, apoa1ljpme 1.10 to 1.24x, cellulose and stmv 1.06 to 1.14x.
   - Depends on probe 1b and a bitwise force diff against 6df2b8bcb plus 71a602b43 with DeterministicForces=true.
   - Natural extension: put computeBondedForces in its own pass too. It reads posq and writes longForceBuffer, and the list chain touches neither, so tracked hazards let bonded overlap findBlocks with no concurrent encoder.
   - Apple8: off, keyed on Apple9 or 16 or more cores, until an M2 screen shows no loss over 1%. M2 memory: pmeForce is 16 B/atom (32 for LJPME), but it isn't allocated while the path is off.

3. Chunked atom-owner bonded kernel, owned by atomics, about 1 day including the bitwise long-force-buffer diff.
   - Gain: apoa1rf 1.13 to 1.15x, apoa1pme 1.11 to 1.13x, cellulose 1.12 to 1.14x, apoa1ljpme and stmv 1.08 to 1.10x, pme and dhfr about 1.05x.
   - Halve these if 1a shows bonded only half atomic-bound.
   - Apple8 runs the same kernel with a 12 KB pad. M2 memory: the plan buffer is about 5 MB at apoa1 size and 40 to 50 MB on stmv, allocated once.

4. Wait-free step phase A, owned by dispatch, about 0.6 day.
   - Gain: gbsa about 1.07x and rf about 1.08x at base, minus whatever the poll wait already took. apoa1 and larger stay on today's path.
   - Depends on probe 1c.
   - Apple8: the capacity budget comes from recommendedMaxWorkingSetSize. Query it on the M2 rather than assume. Given the M2's memory pressure, I would start the Apple8 budget low enough that only gbsa (0.42 MB) is admitted until an m2-lane peak-memory run clears the 36 MB rf/pme/dhfr bound.

5. Native GBSA OBC kernels, owned by nonbonded, stage A 0.3 day and stage B about 1 day.
   - Gain: gbsa single 1.10 to 1.17x, mixed 1.06 to 1.10x. Only one test benefits.
   - Apple8 runs parts (a) and (b). The one-tile-per-SIMD-group launch is Apple9 only until an M2 A/B. M2 memory: none.

6. Fused LangevinMiddle step, owned by mixed, 1.5 to 2 days.
   - Single: 3 to 4% on rf, pme, dhfr and gbsa.
   - Mixed: pme, rf and dhfr about 1.11x on top of c1+c2, and 1.16 to 1.21x at base.
   - This is the largest lever for the weakest column, which is why it ranks above the dual list despite a small single gain.
   - Depends on the c-bundle landing, since c1, c3 and c4 become device functions inside it, and on drift.py and constraints.py on both chips.
   - Apple8 runs the same kernel. Screen it there, because the M2 allocates peak registers. M2 memory: skipping oldDelta on the fused path saves memory.

7. GPU-gated rebuild chain, then the dual list with a SIMD prune, owned by nblist. About 0.5 day for the gate and 1 to 1.5 days for the dual list.
   - The gate alone is worth about 1 to 1.5% after sort2.
   - Dual list: rf 6 to 12%, pme 4 to 8%, apoa1 4 to 9%, cellulose and stmv 3 to 5.5%.
   - Depends on the NB_PAD arm (1f), a probe of zero-threadgroup indirect dispatch (Apple documents nothing about it), and forces against Reference after 50 to 100 MD steps.
   - Apple8: every lever is Apple7 or lower. M2 memory: the outer list costs about 3 MB at dhfr size, 15 MB at apoa1, 55 MB for cellulose and 90 to 130 MB for stmv. Enable it on the M2 only under a small working-set fraction, or run p_out = p_in.

8. Int-tile PME spread, owned by pme, about 0.3 day.
   - Gain: 2 to 10% on the PME tests, less once item 2 hides the spread.
   - Apple9 only. The M2 keeps the fixed-point spread. M2 memory: none.

9. Super-cluster list with a threadgroup j-force table, owned by nonbonded and nblist, 2 to 3 days.
   - Gain: a further 1.10 to 1.20x on apoa1rf, less elsewhere.
   - Depends on items 1 and force words being measured, and on the CPU distinct-j count coming in at 0.7 or lower.
   - Apple9 only. M2 memory: none, since the M2 keeps the old format. The Ultra pays about 10 MB on apoa1rf and 110 MB on stmv.

10. Fused VkFFT convolution, owned by pme, about 0.5 day. Worth 1 to 4%, and close to zero once item 2 lands. Last.

The concurrent encoder with an accumulate class, owned by dispatch, is worth building only if item 2's pass split fails to overlap.

3. Interactions with tonight's incremental work

- pme float atomics (71a602b43) stay. Every PME design measures on top of them. The MSL 4.1 tiled and tiled41 lab kernels become throwaway if the int tile wins, and they are already dead on the M2.
- The pme stream flip competes directly with the pass split. Whichever loses probe 1b is throwaway, and both need the plain-store fold rather than emulated atomics.
- nblist sort2 and copyShortList stay. The gated chain needs copyShortList, because a blit cannot be gated. Gating and the dual list make sort2 run less often, which shrinks its marginal value to the outer-build fraction.
- computeRange and pme nosort stay and do not conflict with any native design.
- The tiles rule stays, but it conflicts with the dual list's outer build. That build assumes batch 1 so each SIMD group can record its row's chunk starts without atomics. Under the dual list the tiles rule only pays on outer builds. It also raises the wait-free capacity bound to totalTiles + numAtomBlocks x batch.
- mixed c1, c3 and c4 carry into the fused kernel as device functions, and c2 stays in df64.metal. c1's edit to the common integrationUtilities.cc, which moves the OpenCL denominator, becomes unnecessary once the fused Metal kernel owns the constraint math. Only that form of c1 is throwaway, not its substance. c5 has to be re-expressed inside the fused kernel.
- The dispatch poll wait stays as the path for apoa1 and larger, and for the M2 when capacity isn't admitted. Wait-free replaces it on gbsa and rf, and it also subsumes DISPATCH_EARLY. DISPATCH_MODE=auto is mostly superseded by the pass split.
- Force words stays and stacks with x-resident tiles. Both edit nonbonded.metal lines around 221-231 and 262-268, so do words first, then x-resident. Its fold must be ordered with pmeForce's fold in the serial encoder, after nonbonded. Any plan to extend words to bonded becomes throwaway if the chunked bonded kernel lands, since chunking cuts adds 8 to 14x against words' 2 to 1.
- The nonbonded TGF, TGP and TGA bundle decides whether GBSA stage B rotates or stages j data. Settle it before x-resident rebases.

4. Ceiling

Method: start from the review's incremental midpoint and subtract the native designs' savings in microseconds, with overlap between designs removed. "Half" means each design delivers half its own central estimate. "Central" means every design hits its central estimate, capped by a data-based bound from the atomics lane's plain-RMW probe. That probe removes all atomic cost and yields only 1.19x (rf), 1.33x (pme), 1.74x (apoa1rf) and 1.80x (apoa1pme) per force evaluation, so no accumulation redesign can beat it.

All ratios are Metal over OpenCL single on the Ultra.

| Test | Single now | Review incremental | Native, half | Native, central | Mixed now | Review mixed | Native mixed, half to central |
|---|---|---|---|---|---|---|---|
| gbsa | 1.080 | 1.10 to 1.15 | 1.26 | 1.42 | 0.715 | 0.76 to 0.80 | 0.93 to 1.15 |
| rf | 1.071 | 1.25 to 1.35 | 1.51 | 1.75 | 0.718 | 0.88 to 0.95 | 1.08 to 1.34 |
| pme | 1.033 | 1.30 to 1.40 | 1.61 | 1.80 | 0.765 | 0.98 to 1.07 | 1.22 to 1.49 |
| amber20-dhfr | 1.015 | 1.28 to 1.36 | 1.57 | 1.75 | 0.732 | 0.94 to 1.02 | 1.20 to 1.45 |
| apoa1rf | 1.067 | 1.10 to 1.22 | 1.38 | 1.70 | 0.863 | 0.95 to 1.01 | 1.14 to 1.46 |
| apoa1pme | 1.068 | 1.28 to 1.38 | 1.60 | 1.85 | 0.924 | 1.12 to 1.20 | 1.37 to 1.64 |
| apoa1ljpme | 1.129 | 1.40 to 1.52 | 1.70 | 1.90 | 1.008 | 1.28 to 1.38 | 1.51 to 1.74 |
| amber20-cellulose | 1.129 | 1.30 to 1.42 | 1.62 | 1.85 | 1.018 | 1.18 to 1.28 | 1.46 to 1.72 |

stmv has no OpenCL baseline. Over current Metal I expect about 1.55x (half) to 1.8x (central), against the review's 1.25 to 1.35x.

I would plan on the half column: single about 1.25 to 1.70, mixed about 0.93 to 1.51. Nothing reaches 2x at that level. With every design at central, the PME family and cellulose come to about 1.8 to 1.9. On pme, apoa1pme and apoa1rf those central values sit near the free-atomics bound. That bound assumes the atomic tax goes to zero, the PME chain is largely hidden, and list rebuilds are mostly gone, all at once, and none of those designs gets atomics to zero. So I would not forecast 2x on any test in single, and nothing gets close in mixed. gbsa tops out near 1.4 because its kernels are pair-math bound: the free-atomics probe gave 1.05x.

4x cannot come from implementation work at equal arithmetic. Both platforms run on the same GPU, and after the atomic tax the remaining step is pair math, FFT and list build, which OpenCL's compiled shared kernels already run at similar efficiency. A 4x ratio would mean removing about 75% of the GPU work OpenCL does. Two routes exist, and neither is legitimate under the current benchmark:
- Changing the computation: grid, cutoff, FP16 or multiple time stepping. The Reference gate or the benchmark contract rules these out.
- Changing the metric to aggregate throughput from several simulations sharing the 60-core GPU. Small systems like gbsa leave most cores idle, and Metal can run independent queues. Whether Apple's OpenCL overlaps across processes is unmeasured, and benchmark.py doesn't measure this anyway.

5. The single most important experiment

Run 1a: the atomics lane's existing 1-atomic and plain-RMW variants in counters mode, reading computeBondedForces and computeNonbonded per kernel on apoa1rf, apoa1pme, cellulose and rf, at low load.

It needs no new kernel code and fits in one lease slot. It decides three of the four largest native line items at once: the chunked bonded kernel (8 to 15% on five tests), x-resident tiles, and the super-cluster list. It also sharpens force words' forecast, which the review calls the high-variance freeze entry.

The atomic tax is the largest pool Apple's hardware creates and OpenCL's shared kernels ignore: up to 657 us of apoa1pme's 1483 us force evaluation. Today that number exists only for a whole force evaluation, measured under load. If bonded turns out gather-bound and computeNonbonded turns out math-bound, the roadmap shrinks to the pass split, wait-free, GBSA and the fused integrator, and the realistic ceiling drops by 0.1 to 0.2 on the large tests.

The PME split-pass probe (1b) is a close second. It is the only lever the free-atomics bound does not cap.

Sources are the ones the designs cite, plus /Users/amir/code/mini/openmm-metal-lab/experiments/028-ultra-max/review-20260924T2120Z.md for the freeze forecast, merge order and ceiling table, and lanes/atomics.md, nblist.md, dispatch.md, pme.md, mixed.md, m2.md and nonbonded.md in the same directory.

## Area: Neighbor list construction: findBlockBounds, computeSortKeys, block sort (sortShortList2 or the bucket sort with computeRange), sortBoxData, findBlocksWithInteractions, copyInteractionCounts and the rebuild trigger, in /Users/amir/code/mini/hipdelta-gbsa/platforms/metal/src/kernels/findInteractingBlocks.metal, kernels/sort.metal, MetalNonbondedUtilities.cpp (prepareInteractions :398-425) and MetalSort.cpp

### Current cost

Source: profiler lane p1, counters mode, Metal single, M3 Ultra, 6df2b8bcb (experiments/028-ultra-max/lanes/profiler.md and the table in lanes/nblist.md). findBlocksWithInteractions per step: rf 153 us (30.5% of the 501.7 us wall step), pme 138 (21.6% of 639.1), apoa1rf 290 (25.3% of 1144.5), apoa1pme 345 (19.5% of 1772.1), apoa1ljpme 242 (10.1% of 2390.6), cellulose 1007 (15.8% of 6370.6), stmv 2054 (12.6% of 16303.7). Per rebuild: about 284 us on dhfr size (737 blocks), 444 to 518 us on apoa1 (2882 blocks), 1488 us cellulose, about 4.0 ms stmv. Rebuild fraction: rf 50%, pme 54%, apoa1rf 71%, apoa1pme 75%, apoa1ljpme 50%, cellulose 66%, stmv 50%. A non-rebuild launch still costs p10 5.6 us. The block sort runs every step whether or not the list is rebuilt: sortShortList2 48.5 us/step on rf, pme and dhfr (9.7% of rf, 7.6% of pme), 8.6 us on gbsa; on apoa1rf the block bucket sort's computeRange alone is 18.5 us/step (1.6%). Caveat: the per-kernel numbers come from counters mode (one encoder per dispatch, 1.73x slower step on rf) and the denominators from buffers mode, so treat the small-system shares as plus or minus 20%.

### Why today's code is OpenCL-shaped

1. The whole pipeline is recomputed every step and the decision comes last. prepareInteractions (MetalNonbondedUtilities.cpp:417-424) dispatches findBlockBounds, computeSortKeys, the block sort (with a blit copy-back, MetalSort.cpp:107), sortBoxData and findBlocks on every step. The "do we need to rebuild" test is computed inside sortBoxData (findInteractingBlocks.metal:189-202), the fourth dispatch, and only findBlocks checks it (:306). So on the 25 to 50% of steps with no rebuild, the 48.5 us sort, computeSortKeys, sortBoxData's gather and the blit encoder switch all run for nothing. That is the OpenCL/CUDA shape: a fixed kernel sequence with early exits, and no GPU-written dispatch sizes, even though Metal has indirect dispatch (Feature Set Tables 2026-05-21, "Indirect draw and dispatch arguments", Apple3; metal-cpp MTLComputeCommandEncoder.hpp:68). 2. A single list with a single padding (0.08 x cutoff, :394), rebuilt exactly when any atom moves more than padding/2. At 4 fs that is every 1.3 to 2 steps, so the O(N x shell) block search runs 50 to 75% of the time. GROMACS moved to a dual list with cheap GPU pruning for this reason (Pall et al., J. Chem. Phys. 153, 134110, 2020, section II.E). 3. The HIP-derived findBlocks gives one 32-thread SIMD group to each block row of the upper triangle, and blocks are ordered by size bin rather than space (computeSortKeys :126-141). The first rows own their whole neighbor shell, so the kernel time is the serial chain of the longest row: 23 chunks at dhfr size, then for each candidate two dependent global loads (sortedBlocks[block2], then posq), a 32-step ffs loop through threadgroup memory, and a returning global atomicAdd on interactionCount[1] whenever there are single pairs (:541-557). That is why dhfr costs 0.38 us per block and stmv 0.12. 4. It uses the generic sort library: a rank sort in 64-thread chunks, a single-threadgroup computeRange and a blit copy, all to produce a size-binned order that only findBlocks reads. 5. Tile allocation takes a global atomic per flush and per candidate, where SIMD prefix sums could batch it.

### Design 1: Dual list with a GPU-resident SIMD prune (outer list rebuilt rarely, inner list regenerated by a Metal-native prune kernel)

#### Native levers

simd_ballot and popcount compaction, and simd_shuffle to broadcast block-x positions from registers. Both are SIMD-scoped permute operations, Apple6+ (Metal Feature Set Tables, 2026-05-21; MSL spec section 6.10, simd_ballot and simd_shuffle). simd_prefix_exclusive_sum for single-pair offsets, and simd_max/simd_any for the displacement trigger. Both are SIMD-scoped reduction operations, Apple7+ (Feature Set Tables; MSL spec, SIMD-group prefix and reduction functions). Indirect compute dispatch: MTLComputeCommandEncoder::dispatchThreadgroups(indirectBuffer, offset, threadsPerThreadgroup), with DispatchThreadgroupsIndirectArguments {uint32 threadgroupsPerGrid[3]} (vendored metal-cpp MTLComputeCommandEncoder.hpp:47-50 and :68; Feature Set Tables list indirect dispatch arguments from Apple3). With it, the rebuild and prune decisions stay on the GPU and non-rebuild steps launch nothing. Relaxed 32-bit device atomics, already in common.metal:45-51. On Apple9, Dynamic Caching allocates registers per phase of the shader (Apple tech talk 111375, 'On-chip register memory is now dynamically allocated and deallocated over the lifetime of the shader'), so the register-heavy unrolled mask loop does not cap occupancy for the light flush code. That last point is inference.

#### Mechanism

Four pieces, and every consumer keeps today's tile format. (1) Control plane. findBlockBounds already runs one SIMD group per 32-atom block. It also computes each lane's squared displacement against outerPos (positions at the last outer build) and against prunePos (positions at the last prune), reduces both with simd_max, and lane 0 does one atomic_fetch_max on the uint bit pattern (positive floats order like uints). A 1-thread decide kernel reads the two maxima, writes indirect arguments ({n,1,1} or {0,1,1}) for the outer-build chain and for the prune, resets the maxima, and resets interactionCount only when a prune will run. (2) Outer build, gated by an indirect dispatch when maxOuter > p_out/2 or on a forced rebuild. It is today's computeSortKeys, sort, sortBoxData and findBlocks, compiled a second time with PADDING = p_out (0.15 to 0.25 nm) and MAX_BITS_FOR_PAIRS = 0. It writes new outerTiles and outerAtoms arrays. At batch 1 each SIMD group owns its row, so it can record each row's flush-chunk starts without atomics. It stores outerPos. (3) Prune, gated by maxPrune > p_in/2 or by an outer build this step. One SIMD group per row x, with rows longer than twice the mean split in two. Lane j holds atom j of block x in registers. For each outer tile, lane k loads outer atom k and builds its 32-bit mask of x atoms within rc+p_in, using the unrolled fma form from findInteractingBlocks.metal:514-531 with x positions broadcast by simd_shuffle. There is no ffs loop and no threadgroup reads. Then popcount. Masks with 1 to 4 bits become single pairs, placed by simd_prefix_exclusive_sum with one atomic reservation per SIMD per batch instead of one per candidate. The rest are compacted with simd_ballot plus popcount into the same 256-entry threadgroup buffer and flushed 7 tiles per atomic, as in :572-599. The output goes into the existing interactingTiles, interactingAtoms, singlePairs and interactionCount. computeNonbonded, the GBSA and custom nonbonded kernels and AMOEBA (AmoebaCommonKernels.cpp:533-561) see an identical format, and forceArgs indices 7, 17 and 19 are unchanged. It stores prunePos. No exclusion test is needed: the outer build already dropped blocks that have exclusions with x. (4) copyInteractionCounts copies 4 words (inner and outer counts), so the existing single per-step host readback resizes both lists through updateNeighborListSize. Why it is exact: suppose a pair is within rc at time t. At the prune its distance was at most rc + 2*D_prune < rc + p_in. At the outer build it was at most rc + 2*D_outer < rc + p_out. So it is in both lists.

#### Expected gain

Model: new findBlocks-side cost per step = C*k*r_out + P*r, where F = C*r is today's findBlocks us/step. k is the growth in per-build cost at the larger padding: (rc+p_out)^3/(rc+p_in)^3 = (1.1/0.972)^3 = 1.45 for p_out 0.2 nm at rc 0.9, because the long-row tail scales with candidate count. r_out is the outer rebuild fraction: about r/2.8, because the trigger threshold goes from 0.036 to 0.1 nm and displacement stays close to ballistic for the first several 4 fs steps (inference). P is the prune cost: about 20 to 30 us at dhfr size (row tail of 50 to 60 outer tiles at about 0.4 us each), about 40 to 60 us at apoa1, about 200 us at cellulose, and 200 to 400 us at stmv, where it is bandwidth bound (about 130 MB of index reads; posq fits in the SLC). Central estimates of us saved per step, and the whole step: rf 153 -> about 92 (61 us, 12%), pme 138 -> 84 (54 us, 8.4%), apoa1rf 290 -> 185 (105 us, 9.2%), apoa1pme 345 -> 216 (129 us, 7.3%), apoa1ljpme 242 -> 150 (92 us, 3.9%), cellulose 1007 -> 654 (353 us, 5.5%), stmv 2054 -> 1214 (840 us, 5.2%). My ranges, with k from 1.3 to 1.8 and an interval ratio from 2 to 3.5: rf 6 to 12%, pme 4 to 8%, apoa1rf 5 to 9%, apoa1pme 4 to 7%, apoa1ljpme 2 to 4%, cellulose 3 to 5.5%, stmv 3 to 5%. Mixed gains the same microseconds on longer steps, about 0.7x the ratio. gbsa: none. The gain scales with C, so it shrinks in proportion to whatever the nblist lane's batch, prefetch and pair-buffer knobs take off the per-rebuild cost. A phase-2 option GROMACS uses (inner buffer near zero with a prune every step) could also cut computeNonbonded tiles by about 8 to 12%, but I did not count it.

#### Apple8 (M2) fallback

The same code runs on the M2. Every lever is Apple7 or lower: reductions and prefix sums are Apple7, ballot and shuffle Apple6, indirect dispatch Apple3. There are no float atomics and no 64-bit atomics. The only Apple8 concern is memory. Enable the dual list only when the outer arrays fit under a small fraction of recommendedMaxWorkingSetSize (for example 3%). Otherwise set p_out = p_in, and the path degenerates to today's single list plus one prune pass, or the prune is skipped entirely. On a 10-core GPU the row tail matters less and throughput matters more, so r_out and P should be re-measured on the M2 before the default is turned on there.

#### Memory cost

Outer tile arrays are about k x 1.2 of today's interactingTiles and interactingAtoms (132 B per tile): dhfr about +3 MB, apoa1 about +15 MB, cellulose about +55 MB, stmv about +90 to 130 MB. Add 16 B per atom for prunePos (stmv +17 MB), per-row chunk starts (numBlocks x 16 x 4 B, stmv +2 MB), and 16 extra bytes of reads per atom per step for the second displacement (stmv about 17 MB/step, about 25 us).

#### Correctness risks

(1) A stale list is invisible to the forces gate. The review's red flag applies in full: forces against Reference after 50 to 100 MD steps, plus drift.py in NVE, on rf, pme and apoa1pme, both chips. (2) The prune has to run on every outer rebuild and must read the outer list only after the outer build. Serial encoder order gives that; a concurrent-encoder mode from the dispatch lane would need explicit barriers. (3) Atom reordering (ComputeContext.cpp:673) permutes slots. Today the displacement check happens to catch it. The dual path must force both an outer rebuild and a prune after a reorder, explicitly rather than by coincidence. (4) Overflow: an outer overflow must trigger the same resize and setForcesValid(false) path as an inner one. updateNeighborListSize's forceReorder heuristic should keep watching the inner count. (5) Kernels that read interactionCount before this step's prune must not run in between. Today only computeNonbonded and the plugin kernels read it, and they all run after prepareInteractions. (6) Zero-threadgroup indirect dispatches: I found no Apple statement that zero is allowed. Probe it, or fall back to early-exit kernels. (7) The HIPPO/AMOEBA consumers hand-copy the tile layout (review, plugins section). The layout is unchanged, but TestMetalHippoNonbondedForce must run.

#### Prototype size

About 300 to 350 lines: prune kernel about 130 lines MSL; findBlockBounds trigger additions and decide kernel about 50; host side (second findBlocks module with outer defines, outer arrays, indirect-args buffer, dispatch through a new executeKernelIndirect, resize path) about 150. 7 to 9 hours for one agent to a measurable, Reference-checked prototype.

#### Feasible tonight

no

#### First experiment

Zero code, using the nblist lane's existing NB_PAD knob (thousandths of the cutoff). Counters mode on rf and apoa1pme, 1 run each at NB_PAD=80 (base) and NB_PAD=220 (0.2 nm at rc 0.9). Read three numbers: findBlocks median per rebuild (gives k), the fraction of steps with a rebuild (gives r_out), and the computeNonbonded delta (the cost the prune removes). Kill the design if C*k*r_out > 0.6*F_now on either test, because then the prune overhead eats most of what is left. If it survives, the second experiment is the prune kernel alone, driven off an outer list built at NB_PAD=220, checked for bit-identical tiles against findBlocks at NB_PAD=80 on a fresh list.

### Design 2: Fused trigger and GPU-gated rebuild chain (skip sort, sortBoxData and findBlocks on steps that keep the list)

#### Native levers

simd_any, a SIMD-scoped vote (MSL spec, SIMD-group functions; Apple6+ permute per the Feature Set Tables), to compute the per-block displacement test in findBlockBounds, which already runs one SIMD group per block. Indirect compute dispatch, dispatchThreadgroups(indirectBuffer, offset, tpg) (metal-cpp MTLComputeCommandEncoder.hpp:68; Feature Set Tables: indirect dispatch arguments, Apple3). The GPU sizes computeSortKeys, the block sort, the compute copy-back and sortBoxData to zero threadgroups when no rebuild is needed. Relaxed atomic_store for the shared flag and arguments, which avoids the plain-store race (common.metal already uses relaxed atomics).

#### Mechanism

Move the displacement test from sortBoxData (findInteractingBlocks.metal:189-202) into findBlockBounds (:39-124). Each lane compares its atom with oldPositions, simd_any reduces, and lane 0 does an atomic store of 1 to rebuildNeighborList if the test is true or the forceRebuild argument is set. The flag is then known after dispatch 1 instead of dispatch 4. The clear moves out of findBlockBounds (:122-123, which would now race with setters) into copyInteractionCounts, the 1-thread kernel at the end of the chain. That kernel also resets blockSizeRange (today reset in sortBoxData :184-187) and the indirect-args words to {0,1,1}. When a rebuild is needed, findBlockBounds lane 0 also writes the precomputed threadgroup counts into a 4-entry DispatchThreadgroupsIndirectArguments buffer: computeSortKeys, sortShortList2 (or the bucket-sort kernels), the compute copy-back, and sortBoxData. The same thread zeroes interactionCount[0..1], moved from sortBoxData :198-201. MetalSort gets a sortIndirect(data, argsBuffer) entry used only by the block sorter. The PME atom sort keeps today's path. The blit copy-back (MetalSort.cpp:107) cannot be gated, so it becomes the nblist lane's compute copyShortList, dispatched indirectly. findBlocks keeps its flag test (:306) or is gated the same way. Step 1 is plain early exits, which prove the saving. Indirect dispatch replaces them once zero-threadgroup dispatch is confirmed.

#### Expected gain

Whole-step savings equal the per-step cost of the gated kernels times the non-rebuild fraction (1 - r). On base 6df2b8bcb: rf 48.5 x 0.50 = 24 us, plus computeSortKeys, sortBoxData and the blit switch (unmeasured, I guess 3 to 8 us) x 0.5, total 26 to 28 us, 5.2 to 5.6% of 501.7. pme 48.5 x 0.46 = 22 plus 2 to 4, 24 to 26 us, 3.8 to 4.1% of 639.1. dhfr similar to pme. apoa1rf: bucket block sort (computeRange 18.5 plus 4 kernels, I estimate 30 to 40 us) x 0.29, 9 to 12 us, about 1%. apoa1pme x 0.25, about 0.5%. apoa1ljpme about 1%. cellulose and stmv under 1%. gbsa: its 8.6 us sort x its non-rebuild fraction, about 0.5 to 1.5%. Stacked on the lane's SIMD sortShortList2 (48.5 -> under 10 us), the rf and pme gains shrink to about 1 to 1.5%. The independent value is that this becomes the control plane (flag in dispatch 1 plus GPU-written dispatch sizes) that design 1 needs.

#### Apple8 (M2) fallback

Identical code on the M2 (Apple8 has indirect dispatch, Apple3+, and SIMD votes, Apple6+). No float atomics, no new memory. If zero-threadgroup indirect dispatch misbehaves on either family, keep the early-exit variant, which costs one dependent dispatch (about 2 us) per gated kernel on non-rebuild steps.

#### Memory cost

A 48-byte indirect-args buffer. No new per-atom arrays.

#### Correctness risks

(1) Flag lifetime. It must be cleared after its last reader and before the next step's first writer. That holds in the serial encoder with the clear in copyInteractionCounts, but it needs an explicit barrier if a concurrent-encoder mode lands. (2) forceRebuild and the maxTiles resize path (updateNeighborListSize sets forceRebuildNeighborList) must still force a full chain. That is an argument to findBlockBounds, as it was to sortBoxData. (3) Moving the interactionCount reset: it must happen only on rebuild steps and before findBlocks, or computeNonbonded reads a zero count and skips all tiles. The forces gate would catch that, so it is not silent. (4) MetalSort is shared with the PME atom sort, so gate only the block-sorter instance. (5) A missed rebuild is silent to the forces gate, so check forces against Reference after 100 steps. (6) Undocumented zero-threadgroup indirect dispatch: probe it before relying on it.

#### Prototype size

About 100 to 150 lines: MSL about 40 (findBlockBounds trigger, early exits, copyInteractionCounts resets), host about 60 to 100 (args buffer, MetalSort::sortIndirect or an early-exit define for the block sorter, an executeKernelIndirect helper in MetalContext next to executeKernelFlat at MetalContext.cpp:594-611). 2 to 3 hours for the early-exit variant, plus 1 hour for indirect.

#### Feasible tonight

yes

#### First experiment

Early-exit variant only, no indirect dispatch. findBlockBounds sets the flag. computeSortKeys, sortShortList2 (behind a define passed only to the block sorter's module), the copy-back and sortBoxData return when flag == 0. Blit copy stays for the first run if copyShortList has not landed. Counters mode on rf and pme, 1 run each. Pass if the sortShortList2 duration distribution goes bimodal (about 48.5 us on rebuild steps, 3 us or less otherwise) and the step drops about 20 us. Then ctest TestMetalNonbondedForce, TestMetalEwald and TestMetalSort, plus forces against Reference after 100 steps on rf and pme.

### Rejected

Hardware ray tracing (M3 RT units) does not fit this problem on Apple GPUs, and I would not prototype it. Apple says the Apple9 hardware intersector runs BVH traversal in fixed function, but 'the intersection functions are Metal shading language code, so they still must be grouped into SIMDgroups to be run on the shader core', and the intersection query API 'increases the amount of ray trace scratch memory ... as well as disables the reorder stage' (tech talk 111375). A neighbor search over atom or block bounds needs bounding-box primitives with a custom [[intersection(bounding_box)]] function or an intersection_query loop (MSL spec, intersection functions and intersection_query), so every candidate hit runs shader code. Only the inner-node descent is offloaded. OpenMM's search is small and latency bound: 737 to 33k block boxes, where the cost is the serial row tail plus the 32x32 atom mask per candidate. RT would only produce candidate block pairs. The atom-mask and packing stages, which are most of the work, would remain. Periodic boundaries need ghost copies or 27 image queries. The published RT neighbor-search gains are 10 to 60% over cell lists on NVIDIA RTX for LJ (Zhao et al., IJNME 2023, doi 10.1002/nme.7139); about 1.3x at small radius, with a special technique needed for periodic boundaries (arXiv 2601.15633); and 2.2 to 65x for large point clouds through OptiX (Zhu, RTNN, PPoPP 2022). None of them used Apple hardware, and none produced a 32-atom cluster list. Each rebuild would also need a separate acceleration-structure encoder pass for build or refit. On the M2, 'Ray tracing in compute pipelines' is Apple6+ in the Feature Set Tables, but the hardware intersector is Apple9 only, so the M2 would need the fallback anyway. Other rejections. simdgroup_matrix for the distance masks (the Metal analog of HIP's MFMA path at :224-244): a 32x32x4 tile is 16 8x8 multiplies at about 18 cycles each (metal-benchmarks, M1), about 290 cycles, against about 32 to 64 cycles of per-lane FMA, so it loses. A looser trigger (rebuild when d1+d2 > padding instead of 2*d1): for 23k atoms the spacing between the two largest displacements is about sigma/sqrt(2 ln N), so the list lives only 2 to 3% longer. Dropping the per-step host count wait by checking overflow one step late: on overflow, computeNonbonded and the plugin kernels return early (nonbonded.metal:239-241), so one step would silently lose interactions, and making every integrator kernel roll back on the GPU is far out of scope. The dispatch lane's poll wait is the right fix. A cell grid replacing the size sort and the chunk scan: at dhfr size (6.2 nm box, cells of at least rc+pad+2 block radii, about 2 nm) the 27-cell stencil covers the whole box, and at 90k atoms and up the existing large-block ballot already skips 32-block chunks, so the scan is not the proven cost. Revisit only if the nblist lane's NB_TIME phase split shows otherwise. Persistent-grid kernels with inter-threadgroup waits: I found no Apple forward-progress guarantee between threadgroups (the 9074c38f1 computeRange bug is the local example). Work queues that only pull from an atomic counter are fine. MSL 4.1 threadgroup float atomics and acquire/release: this area needs neither, and the review keeps 4.1 out. A Metal 4 port: lab 008 measured 2.16 us per dependent dispatch against 1.88 for classic serial. The lane's incremental knobs (NB_BATCH tiles rule, NB_PREFETCH, NB_PAIRBUF, SIMD sortShortList2, multi-threadgroup computeRange) are not repeated here. Both designs stack on them, and design 1's gain scales down in proportion to whatever they take off the per-rebuild cost.

## Area: Pair kernels: computeNonbonded (all tests) and the GBSA OBC tile kernels computeBornSum and computeGBSAForce1 (gbsa), Metal single on the M3 Ultra with the M2 as fallback

### Current cost

gbsa (2,489 atoms, CutoffNonPeriodic 2.0 nm, 2,231 to 2,462 neighbor tiles, no single pairs): computeNonbonded 54.3 us, computeGBSAForce1 52.0 us, computeBornSum 45.4 us per step. These are GPU-clock numbers from kernels mode, one buffer per dispatch, with about a 5 us floor per kernel (lab 024, experiments/024-hip-delta/results/studio/gbsa-profile/prof1/hdprof-full-kernels-round3.txt). The three add up to about 136 us of real work against gbsa's 268.5 us GPU busy and 293 us wall (028 profiler, lanes/profiler.md), so they are about 50% of the step, and the GB pair of kernels alone is 33%. In gbsa, computeNonbonded carries Coulomb, LJ and the OBC chain-rule term (gbsaObc2.cc is injected through nb.addInteraction). Explicit solvent: I found no 028 per-kernel table for computeNonbonded on this machine (it sits in p1/ on the Studio). The best local evidence is the atomics lane's force-eval probe (lanes/atomics.md, 19:55Z, Metal single, host clock). Replacing the two-op emulated 64-bit add with one non-returning 32-bit atomic made one force evaluation 1.645x faster on apoa1rf (0.818 to 0.497 ms, 321 us saved), 1.192x on rf, 1.276x on pme and 1.408x on apoa1pme. The pme and apoa1pme numbers also include fixed-point PME spreading, per the review. On gbsa the same probe gave only 1.051x. So computeNonbonded on the explicit systems is bound by the number of global atomic ops. The GB kernels are bound by pair math.

### Why today's code is OpenCL-shaped

1) The GB kernels are platforms/common/src/kernels/gbsaObc.cc compiled almost as-is, in the OpenCL 1.2 shape. Every j step reads 5 fields and read-modify-writes 4 accumulators in a 36-byte threadgroup struct, then calls SYNC_WARPS (simdgroup_barrier). That is 32 barriers per tile. Apple's OpenCL has no subgroup shuffles (lab 025 extension list), so this shape made sense there, but Metal has simd_shuffle_rotate_down, which nonbonded.metal already uses. 2) Metal compiles SQRT as __fsqrt_rn = precise::sqrt (MetalContext.cpp SQRT define; library built with MathFloatingPointFunctionsPrecise, MetalContext.cpp:485). OpenCL on the same GPU uses native_sqrt when its accuracy test passes (OpenCLContext.cpp:391). computeGBSAForce1 takes a precise sqrt plus three fast::divide reciprocals on every pair, so here Metal does more work than OpenCL. Its RSQRT(r2) result is dead code. 3) Each pair reciprocates loop-invariant per-atom values (RECIP(params.x), RECIP(4*bornRadius1*bornRadius2)) and computes LOG(u*RECIP(l)), where 1/l is exactly the max() it just reciprocated. That gives 9 transcendental-class ops per pair in computeBornSum and 8 plus RSQRT in the chain term. 4) The GB launch goes through executeKernel, which caps the grid at numThreadBlocks = 12 per core (MetalContext.cpp:590, a METAL-TODO tuned on the M2). That gives 720x64 = 1,440 SIMD groups with a static contiguous split of about 2,400 tiles: 1.67 tiles average, 2 at most, so about 17% tail. 5) computeNonbonded is HIP's tile layout, designed for AMD, which has a native 64-bit global atomic add. Apple has none: MSL 4.1 section 6.16.4.6 gives atomic_ulong only min and max, as verified in the brief and in lab 004. Each lane in each tile issues 6 emulated 64-bit adds, about 12 atomic ops including a returning one. Tiles go to SIMD groups strided (pos0 += totalWarps, nonbonded.metal:242), so the x-block force can never stay in registers across the consecutive same-x tiles that findBlocksWithInteractions writes in chunks of up to 7 (BUFFER_SIZE 256).

### Design 1: 1. x-resident tile runs in computeNonbonded (op-count design for the missing 64-bit atomic)

#### Native levers

Design around a hard Apple fact: there is no 64-bit atomic add on any family (MSL 4.1 spec 6.16.4.6; Feature Set Tables footnote 7, where Apple9's '64-bit atomics' means min and max; brief section 2). Emulation costs 37 G adds/s against 62.5 G/s for one 32-bit atomic and 250 G/s for a plain RMW (atomics lane microbenchmark, 55M adds on the Ultra). The atomic unit's op count is the limit; latency is not (the deferred-carry probe gained nothing). The design keeps the x-atom force in registers across tiles and uses simd_shuffle_rotate_down for the j side as today (MSL 4.1 6.10.2; shuffle Apple6+ per Feature Set Tables). With Dynamic Caching, a few more live registers do not cost Apple9 occupancy (Apple tech talk 111375: 'the maximum register usage no longer dictates how many SIMDgroups can be run').

#### Mechanism

Change the neighbor-list loop in nonbonded.metal from strided to contiguous chunks. SIMD group w takes tiles [w*N/W, (w+1)*N/W) of the combined exclusion plus neighbor index space, with exclusion tiles handled as now and flushed per tile. For neighbor tiles, `force` (the x side) is not zeroed per tile. It carries across consecutive tiles with the same x = tiles[pos]. The 3 x-side emulated adds are issued only when x changes or the chunk ends. The j side keeps its 3 adds per tile, because j atoms are distinct per tile. Adds per lane per tile go from 6 to 3 + 3*(flushes/tiles). findBlocks writes same-x runs of up to 7 tiles, about 6 on average. For apoa1rf I estimate about 78k tiles over 4,800 SIMD groups, so T is about 16 tiles per chunk, about 3.7 flushes, and 3.7 adds per tile (-38%). For rf and dhfr, T is about 4 and adds fall to about 4.3 (-29%). For gbsa, T is under 1, so nothing changes. On the M2 (800 SIMD groups) T is about 6x larger, so the x side nearly vanishes. The kernel is identical on both chips, and the j-side add is a macro, so the atomics lane's force words or an Apple9-only float path can plug in later. The two stack: words makes each add cheaper, and this removes adds.

#### Expected gain

Derived from the atomics probe. Its 40% cut in atomic-op time (1480 to 880 us in the microbenchmark) saved 321 us per force eval on apoa1rf. Giving computeNonbonded 60 to 80% of that (bonded is 185 us in total) means about 190 to 260 us per 40% op-time cut. A 38% add cut should then save about 120 to 220 us after discounting for the probe also removing the returning dependency. That is computeNonbonded -20 to -35% on apoa1rf, and a step of 1144.5 us becomes 1.08 to 1.20x. rf (probe saved 46 us per eval, 29% cut here): 20 to 35 us of 501.7, 1.04 to 1.07x. pme and dhfr: 1.03 to 1.06x. apoa1pme, apoa1ljpme, cellulose, stmv: 1.04 to 1.10x (T is large, but the nonbonded share is diluted by PME and bonded). gbsa: 1.00. Mixed gets the same microseconds on longer steps, about 0.7x the ratio gain. This is an inference from one probe run under load 3 to 3.9. The first experiment below settles it.

#### Apple8 (M2) fallback

The same kernel with no Apple9 feature. It is plain op-count reduction and should help the M2 more, since T is larger with 10 cores. The only M2-specific risk is tail imbalance when N/W is small, and N/W is large on 10 cores.

#### Memory cost

Zero device memory. Three more live floats per lane at most, and they already exist as `force`.

#### Correctness risks

The x force now sums several tiles in float before one realToFixedPoint, so forces are not bitwise equal to base. They differ within float rounding, stay deterministic for a given neighbor list, and exact fixed-point summation keeps order independence across SIMD groups. Gate on rel|dF| against Reference plus a 50 to 100 step energy check. The per-tile singlePeriodicCopy translation depends only on x, so it is safe. Padding entries (j = PADDED_NUM_ATOMS) are unchanged. This edits the same atomicAdd sites as force words (atomics) and the TGF/TGP variants (nonbonded), per review section 4: coordinate the order. HIPPO uses its own kernel source through setKernelSource, but run TestMetalHippoNonbondedForce anyway because it copies the forceArgs layout.

#### Prototype size

About 40 to 60 lines in platforms/metal/src/kernels/nonbonded.metal (loop bounds, carry and flush), 0 host lines. About 1 hour of code, 20 minutes of build, and one lease slot.

#### Feasible tonight

yes

#### First experiment

Counters-mode A/B of computeNonbonded alone on apoa1rf and rf, base 6df2b8bcb against the patch compiled in as default (no env knob), plus forces.py single. Log flushes per SIMD group from one debug run to confirm T and the run length. Keep it if computeNonbonded drops 12% or more on apoa1rf. Kill it if the drop is under 5%, which would mean the kernel is not op-bound in situ and the probe's gain came from bonded or the returning latency.

### Design 2: 2. Native MSL GBSA OBC kernels: register-resident, transcendental-lean, one tile per SIMD group on Apple9

#### Native levers

simd_shuffle_rotate_down register rotation in place of threadgroup staging plus a simdgroup_barrier per j step (MSL 4.1 6.10.2, Apple6+). fast:: math chosen per term under safe math mode (MSL 4.1 1.6.3: fast rsqrt, divide and exp; the library already maps HIP's fast intrinsics this way). Apple9 Dynamic Caching lets the GB kernels launch one SIMD group per tile without the M2-era occupancy cliff (tech talk 111375). Apple9's concurrent FP32 and integer issue needs work from several SIMD groups (same talk: 'up to 2x ALU performance'), which argues for more resident SIMD groups than 24 per core. The Metal kernel lives in platforms/metal/src/kernels/gbsaObc.metal, which the CMake glob embeds automatically (platforms/metal/CMakeLists.txt:90).

#### Mechanism

A Metal-only replacement for computeBornSum and computeGBSAForce1, plus a Metal variant of the gbsaObc2 chain term, chosen by a MetalCalcGBSAOBCForceKernel subclass (MetalKernelFactory.cpp:78). For the prototype, a 5-line source swap in MetalContext::compileProgram is enough. (a) Arithmetic. Per-atom invariants (1/r_i, s_i^2, 1/B_i) are computed once per tile at load and rotated with the j data. One reciprocal of max(r_i,|r-s_j|)*(r+s_j) yields both l and u. ratio = LOG(max*u). Per-pair transcendental-class ops: computeBornSum 9 to 5 (RSQRT, 2 RECIP, 2 LOG). computeGBSAForce1 5 to 2: D = r2*0.25*invB_i*invB_j, invDen = rsqrt(r2 + a2*exp(-D)), E = qq*invDen, Gpol = E*invDen^2, which replaces precise sqrt and three reciprocals. Chain term 8 to 4. (b) Data movement. The j position, charge or params and the j accumulators live in registers and rotate as in nonbonded.metal. That drops 13 threadgroup accesses and one barrier per j step. Whether rotation beats threadgroup staging on Apple9 is exactly what the nonbonded lane's TGP/TGF screen measures tonight, so make the choice a compile-time define and take their answer. (c) Launch. On Apple9, dispatch through executeKernelFlat with nb.getNumForceThreadBlocks() groups (2400x64, one tile per SIMD group, strided like computeNonbonded) instead of the 720x64 cap. Keep the cap on Apple8 until measured.

#### Expected gain

Kernel level, assuming the lab 024 times are mostly ALU issue with transcendentals at 4 to 8 cycles and FMA at 1 (throughputs from metal-benchmarks, M1-era, a floor for Apple9). computeGBSAForce1 about 47 us net becomes 27 to 33 us (-14 to -20 us). computeBornSum about 40 us becomes 28 to 32 us (-8 to -12). The chain-term share of gbsa's computeNonbonded (about 49 us net) saves 5 to 10 us. The launch-tail fix (2 against 1.67 tiles) overlaps with these, so I don't add it separately. Total -27 to -42 us of 293 us wall: gbsa single 1.10 to 1.17x, or 1.19 to 1.26 against OpenCL, up from 1.080. gbsa mixed gains the same microseconds on a step of about 440 us, 1.06 to 1.10x, taking 0.715 to about 0.76 to 0.79. No other benchmark test uses GBSA. If the kernels turn out latency-bound rather than issue-bound, the cut dependency chains still help, but by less. The first experiment measures that directly.

#### Apple8 (M2) fallback

Parts (a) and (b) use nothing Apple9-only, so the M2 runs the same kernel. Part (c) is chosen by device->supportsFamily(MTL::GPUFamilyApple9): Apple8 keeps 12 threadgroups per core until an M2 A/B shows the one-tile launch wins. The common gbsaObc.cc stays untouched for OpenCL, CUDA and HIP, so the OpenCL denominator does not move (review red flag). The CPU path gbsaObc_cpu is unaffected.

#### Memory cost

None on device. The per-atom invariants are recomputed per tile in registers. No new arrays, no change to bornRadii, obcChain, bornSum or bornForce.

#### Correctness risks

fast::rsqrt of den^2 in place of precise sqrt plus a divide changes the last few ulps of the GB energy and forces. That is the same class of approximation the nonbonded kernel already makes with RSQRT, but check rel|dF| and rel|dE| against Reference on gbsa (base rel|dF| 2.468e-05). The algebraic l*u trick must keep the r - s_j sign and max() semantics exactly, including the (r_i < s_j - r) 2*(1/r_i - l) correction and the j != tgx self-exclusion on diagonal tiles. The chain term goes through nb.addInteraction, so the Metal variant has to keep BORN_FORCE and OBC_PARAMS names identical. Run TestMetalGBSAOBCForce, TestMetalCustomGBForce (a separate path, but a sanity check) and a 100-step energy-drift run. Keep the defines path (USE_CUTOFF, USE_PERIODIC, NoCutoff enumeration) complete, because GBSAOBCForce with NoCutoff uses the triangular tile enumeration.

#### Prototype size

Stage A, tonight: a Metal copy of gbsaObc.cc with only the arithmetic changes in (a), keeping its threadgroup structure, plus the compileProgram swap. About 120 lines, 1.5 to 2 hours plus build. Stage B: register rotation, the chain-term subclass and the Apple9 launch rule, about 350 more lines, most of a day.

#### Feasible tonight

yes

#### First experiment

The cheapest kill test, about 15 lines: in a Metal-only copy of computeGBSAForce1, replace SQRT, RECIP(denominator), RECIP(denominator2) and RECIP(4*alpha2) with one fast rsqrt and a per-atom 1/B, then read computeGBSAForce1 in counters mode on gbsa, base against patch, same lease slot. Continue to the full stage A if the kernel drops 10% or more. If it drops under 5%, the GB kernels are not issue-bound and the family narrows to the launch-shape change (c) alone.

### Design 3: 3. Super-cluster neighbor list with threadgroup-privatized j forces (explicit solvent, multi-day)

#### Native levers

Threadgroup memory as a software-managed accumulator. Apple9 serves it from the same flexible on-chip cache as registers (tech talk 111375: threadgroup memory is 'a cache too'). The limit is 32 KB per threadgroup on Apple9 (Feature Set Tables limits table, in the brief). Merging goes through SIMD ballot and shuffle (Apple6+/Apple7+). An optional later path uses MSL 4.1 threadgroup atomic_float add (MSL 4.1 spec 6.16.4, per the brief), kept out tonight per the review.

#### Mechanism

findBlocksWithInteractions emits tiles grouped by super-cluster: G (4 to 8) consecutive sorted x blocks handled by one threadgroup. Each interactingAtoms entry also gets a slot index into a deduplicated per-cluster j-atom table of at most about 2,000 atoms (3 floats each, 24 KB). computeNonbonded accumulates j forces into that threadgroup table with 32-bit threadgroup atomics or float CAS (low contention, since the 32 j atoms in a tile are distinct), keeps x forces in registers as in design 1, and flushes each distinct j atom with one global emulated add at the end. Global j-side adds per tile fall from 3 to 3*distinct/slots.

#### Expected gain

By my rough geometric estimate, the neighbors of G adjacent blocks overlap about 2 to 2.5x (about 830 half-list neighbors per block, 130 tiles or 4,160 j slots per threadgroup on apoa1rf, and I guess 1,500 to 2,000 distinct). Stacked on design 1, that takes total adds per lane per tile from about 3.7 to about 1.9. If apoa1rf's computeNonbonded is as op-bound as the probe suggests, that is a further -15 to -30% of the kernel: apoa1rf about 1.10 to 1.20x on top of design 1, cellulose and stmv 1.05 to 1.12x. Unverified. It rests on an overlap estimate I have not measured.

#### Apple8 (M2) fallback

The M2 keeps design 1's path. On Apple8, 24 to 30 KB of threadgroup memory per group caps residency at about 2 groups per core (about 60 KB per core per metal-benchmarks, M1/M2), which would starve latency hiding. So the super-cluster kernel is compiled only when supportsFamily(Apple9), and the list keeps both formats or builds the slot index only on Apple9.

#### Memory cost

About 4 bytes more per interactingAtoms entry for the slot index: about 10 MB on apoa1rf, about 110 MB on stmv (roughly 870k tiles). That is fine on the Ultra and matters on the 8 GB M2, which is why the M2 keeps the old format. Threadgroup: 24 to 30 KB per group.

#### Correctness risks

This changes the neighbor-list format that findBlocks, sortShortList2, the GB kernels and hippoNonbonded.cc all read (nblist's and plugins' territory). Slot-table overflow needs a spill path to direct global adds. Order-independent fixed point stays exact at the global level, but threadgroup float accumulation adds rounding. Rebuild-rate and padding interactions need the 50 to 100 step Reference check the review demands for any list change.

#### Prototype size

About 500 to 700 lines across findInteractingBlocks.metal, nonbonded.metal and MetalNonbondedUtilities.cpp. 2 to 3 days.

#### Feasible tonight

no

#### First experiment

GPU-free: download interactingTiles and interactingAtoms once for apoa1rf, rf and cellulose from a Python-hooked build, then count distinct j atoms per 130-tile chunk of G consecutive x blocks on the CPU. Kill the design if distinct/slots is above 0.7, since the gain would be under 1.3x fewer j adds. Build it only after design 1 and force words are measured, because both shrink the pool it aims at.

### Rejected

simdgroup_matrix for distances (r2 = |a|^2 + |b|^2 - 2a.b as 8x8 products, Apple7+). Even with coordinates relative to the block center (|a| up to about 1.5 nm), the float cancellation error in r2 is about 2*6e-8*4.5 = 5.4e-7 absolute. That is 8.6e-6 relative at r = 0.25 nm, so about 5e-5 in LJ forces, and 5e-5 in r2 for GB's bonded pairs at 0.1 nm. Both are above the gate's 2.5e-5 rel|dF|. The MSL spec leaves the lane mapping of simdgroup_matrix elements unspecified, so the results need a threadgroup store and reload, while the distance math is only 5 to 6 of 50 to 100 ops per pair (a ceiling of about 6%). findBlocks already uses the |a|^2/2 trick where padding absorbs the error. Function constants: OpenMM already bakes every specialization in as a #define at source compile, so codegen is identical. They would only cut context-creation compile time, not step time. Native float device atomics for forces: fast on Apple9, but lab 004 measured the M2 at 190.8 ms against 0.34 ms (a CAS loop), results become order dependent, and the atomics lane's force words reaches the same one-op-per-add count deterministically. So it lives there, not here. Privatizing whole-system bornSum or forces for gbsa in threadgroup memory: bornSum fits (2,496 x 4 B), but the flush is 720 groups x 2,496 = 1.8M ops against about 300k today, and the GB forces (4 fields, 40 KB) exceed 32 KB. gbsa is not atomic-bound anyway (probe 1.051). FP16 for GB or LJ math: an 11-bit mantissa is far outside the 2.5e-5 gate. A persistent kernel with a device-wide barrier between the BornSum, Force1 and chain passes: Metal gives no forward-progress guarantee across threadgroups, so spinning can deadlock. Fusing reduceBornSum and reduceBornForce through per-atom last-arriver counters: that adds about 2 int atomics per lane per tile (j atoms are atom-level, not block-level) to save 2 dependent dispatches of about 4 us each, about 3% of gbsa. Too little for the risk. Storing per-pair chain-rule terms from the BornSum pass to skip recomputing them: about 20 MB written and read per step at about 800 GB/s is about 50 us, more than the math it saves. MSL 4.1 threadgroup float atomics tonight: the review says keep 4.1 out, and Apple8 support is unverified. Hardware ray tracing for pair search belongs to nblist, and bounding-volume traversal does not produce the 32-wide tiles these kernels consume. Metal 4 encoders: lab 008 measured 2.16 us per dependent dispatch against 1.88 classic, which gives these kernels nothing. Sources: MSL 4.1 spec (developer.apple.com/metal/Metal-Shading-Language-Specification.pdf), Metal Feature Set Tables PDF, Apple tech talk 111375 (developer.apple.com/videos/play/tech-talks/111375/), research/2026-09-24-apple-gpu-metal-brief.md, lanes/atomics.md, experiments/024-hip-delta README and prof1 tables, and the worktree files named above.

## Area: Per-step orchestration on the Metal platform: command buffers, dispatch count, the per-step host event wait, serial-encoder barriers, and the small integration and constraint dispatches

### Current cost

All numbers are Metal single on the M3 Ultra. Wall time and GPU busy come from profiler lane block 1, buffers mode (lanes/profiler.md). The per-dispatch floor comes from lab 008 and the integration census from lanes/mixed.md.
(1) Host-side idle gap per step: gbsa 24.5 us of 293.0 (8.3%), rf 45.9 of 501.7 (9.1%), pme 6.9 of 639.1 (1.1%), apoa1rf 13.7 (1.2%), apoa1pme 12.4 (0.7%), apoa1ljpme 11.3 (0.5%), cellulose 41.9 (0.7%), stmv 149.9 (0.9%). The review traces rf's gap to a 33 us median start delay at the force-to-integration buffer boundary. Commits are not late: the next buffer is committed 85 to 480 us before the previous one ends.
(2) Every step has 2 command buffers and 1 host event wait. The first commit is downloadCountEvent->enqueue() in prepareInteractions. The second is the commit plus wait in computeInteractions (MetalNonbondedUtilities.cpp:449-451).
(3) Dispatch floor: 1.88 us of GPU time per dependent dispatch in a serial encoder (lab 008). Per step that is gbsa 20.3 x 1.88 = 38 us (13%), rf 18.3 dispatches = 34 us (6.9%), pme 27.3 = 51 us (8%), apoa1pme 31.3 = 59 us (3.3%), apoa1ljpme 47.3 = 89 us (3.7%).
(4) Integration plus constraints, pme single census, one command buffer per kernel with about 5 us overhead each: SETTLE pos 10.8, SETTLE vel 8.8, SHAKE pos 7.7, SHAKE vel 6.4, Part1+2+3 21.0, total 54.7 us. That is roughly 30 to 55 us in the batched step. In mixed the same kernels add 234 us per pme step and 126 us per gbsa step.
(5) Implicit barrier after every dispatch in the serial encoder: about 5% on large systems. One encoder per dispatch ran apoa1pme 0.960x, cellulose 0.940x and stmv 0.944x of the serial time.
(6) On non-rebuild steps (25 to 50% of steps in the explicit tests) the list chain still runs: computeSortKeys, sort (sortShortList2 48.5 us on rf, pme and dhfr at base), sortBoxData, and findBlocks (5.6 us early exit, p10).

### Why today's code is OpenCL-shaped

Each point below is a design choice carried over from discrete-GPU CUDA and OpenCL. Each one costs time on an Apple GPU with unified memory.
(a) The host owns the neighbor-list capacity, so every step it reads the tile count back and blocks. MetalNonbondedUtilities.cpp:449-451 does commit(), downloadCountEvent->wait() and updateNeighborListSize(). An overflow invalidates the forces and they are recomputed (:455-490). That round trip is the only reason the step splits into 2 command buffers. It is also the likely cause of the rf and gbsa gaps: lab 024 found a blocked waiter delayed an already-committed buffer by about 40 us, and the profiler sees 33 us at that boundary. The capacity starts at a guess, maxTiles = 20*numAtomBlocks (:257), and grows by 1.2x. Yet the code already caps it at the hard bound totalTiles = n(n+1)/2 (:472-474). For systems below about 1000 blocks that bound is at most 36 MB, which is nothing on a 96 GB unified-memory machine. So the count wait exists only to save memory we do not need to save.
(b) copyInteractionCounts (findInteractingBlocks.metal:635) copies the counts into a second "pinned" buffer, although interactionCount is already MTLStorageModeShared (MetalArray.cpp:53). This is the CUDA pinned-memory habit.
(c) The platform uses one serial compute encoder per buffer (MetalQueue.cpp:47, computeCommandEncoder() with no dispatch type). That is an in-order OpenCL queue: a full drain after every kernel, even between force kernels whose fixed-point atomic adds commute exactly (common.metal:57-67; lab 004 found them exact under contention).
(d) The integrator is 5 to 7 generic kernels: langevinMiddle.cc Part1/2/3, plus SETTLE and SHAKE for velocities and for positions (MetalIntegrationUtilities.cpp:59-81). They pass velm, posDelta and oldDelta through device memory between launches. They are composable across integrators and platforms, but each boundary costs a launch and a drain. In mixed, each boundary also costs a df64 to IEEE pack and unpack on every mixed4 (df64.metal:124-230).
(e) The rebuild decision is made in sortBoxData (findInteractingBlocks.metal:192-201), after the sort has already run. Kernels that could be skipped are still launched, because OpenCL 1.2 has no GPU-sized dispatch.
(f) flushPeriodically is Windows-only (CommonKernelUtilities.h:86-97), so on macOS the commits come only from the count-event machinery.

### Design 1: Wait-free step: GPU-owned neighbor list with a hard-bound capacity, one command buffer per step, bounded run-ahead, and indirect-dispatch rebuild skipping

#### Native levers

1. Unified memory with MTLStorageModeShared, which is the default on Apple silicon: "The CPU and GPU share access to the resource, allocated in system memory" (developer.apple.com/documentation/metal/mtlstoragemode/shared). The worst-case list capacity is cheap here, and the host reads GPU-written counters without a blit.
2. Indirect dispatch, MTLComputeCommandEncoder dispatchThreadgroups(indirectBuffer, offset, threadsPerThreadgroup), macOS 10.11+. Apple: "The GPU fetches parameters from the indirect buffer just before the thread grid starts ... without latency from data transfer between the CPU and the GPU" (developer.apple.com/documentation/metal/mtlcomputecommandencoder/dispatchthreadgroups(indirectbuffer:indirectbufferoffset:threadsperthreadgroup:); metal-cpp MTLComputeCommandEncoder.hpp:68).
3. MTLSharedEvent: encodeSignalEvent once per step (MTLCommandBuffer.hpp:156), read on the host with signaledValue() (MTLEvent.hpp:72) as a non-blocking progress counter, never waitUntilSignaledValue on the hot path.
4. Queue backpressure: makeCommandQueue() equals maxCommandBufferCount 64, and makeCommandBuffer() "blocks the calling CPU thread when the queue doesn't have any free command buffers". Command buffers hold strong references to encoded resources, so a host-side resize during run-ahead is safe (developer.apple.com/documentation/metal/mtldevice/makecommandqueue() and mtlcommandqueue/makecommandbuffer()).
5. MSL atomic_compare_exchange_weak_explicit on device atomic_uint, memory_order_relaxed, since Metal 2 (MSL spec 6.15.4). It gives an exact single-pair reservation that never over-commits.

#### Mechanism

Phase A: hard-bound capacity with no host wait. Phase B, optional, stacks on A: rebuild skipping. Phase A alone is the design.

Phase A1, capacity. When (totalTiles + numAtomBlocks) x 132 B fits a device budget, allocate interactingTiles and interactingAtoms at that bound at init. The budget is 64 MB and at most 1% of recommendedMaxWorkingSetSize, where 132 B is 4 B of tile index plus 32 x 4 B of atoms. Each atom2 lands in at most one tile slot per block row, so the tile count cannot exceed totalTiles with NUM_TILES_IN_BATCH = 1, and the existing code already caps maxTiles there (MetalNonbondedUtilities.cpp:472-474). Tile overflow becomes impossible. The capacity is 0.42 MB for gbsa (78 blocks) and 36 MB for rf, pme and dhfr (737 blocks). apoa1 and larger stay on today's path. If the nblist lane's batch rule lands, use totalTiles + numAtomBlocks x batch.

Phase A2, single pairs. Replace the atomicAdd reservation on interactionCount[1] (findInteractingBlocks.metal:556) with a CAS loop that reserves only when start + sum <= maxSinglePairs. When the reservation fails, the warp routes those atoms into the tile buffer, the storeAsSinglePair == false path. A pair-array overflow then moves pairs into tiles and never drops them, and count[1] never exceeds capacity. A third counter records spilled atoms so the host can grow singlePairs lazily.

Phase A3, submission. prepareInteractions stops calling downloadCountEvent->enqueue(). computeInteractions stops committing and waiting. MetalCalcForcesAndEnergyKernel::finishComputation commits once per step and encodes a signal on a per-queue step event, so a buffer holds integration(N-1) + clear + list(N) + forces(N). Before encoding step N+K, the host polls that event for step N, with K = 2 and a 10 us usleep poll per the review's recipe. That bounds run-ahead without a kernel-side waiter and without hitting the 64-buffer block.

Phase A4, host heuristics. copyInteractionCounts keeps its dispatch but writes into a shared ring slot [step % 8] (tiles, pairs, spills). The host runs the reorder heuristic (the 1.1x tilesAfterReorder trigger) and the lazy singlePairs growth from slots whose step the event already reports complete.

Phase B. Move the per-atom rebuild test (|posq - oldPositions|^2 > 0.25 PADDING^2, now at sortBoxData:196-201) into findBlockBounds, which already loads posq. The threads that see motion, or forceRebuild, write fixed MTLDispatchThreadgroupsIndirectArguments {n,1,1} into a small args buffer. computeSortKeys, the sort kernels, sortBoxData and findBlocks dispatch indirectly from it. The nonbonded kernel's thread 0 resets the args to {0,1,1} for the next step. On non-rebuild steps the whole chain after findBlockBounds becomes empty dispatches.

#### Expected gain

Phase A removes the per-step wait and one buffer boundary. The best case takes the measured idle gap down to the pme-like floor of about 3.5 us per boundary.
- gbsa: 24.5 to about 4 us, saving about 20 us per 293 us step, 1.07x. Ratio to OpenCL 1.080 goes to about 1.15.
- rf: 45.9 to about 5 us, saving about 40 us per 502 us step, 1.08 to 1.09x. Ratio 1.071 goes to about 1.16.
- pme and dhfr: 6.9 to about 3.5 us, about 0.5%.
- apoa1 and larger: 0, since they stay on the old path.
- Mixed: the same or fewer absolute microseconds, gbsa and rf about 3 to 5%.
The review's poll wait targets the same gap at about 10 us each. Phase A is the full version and replaces it.

Phase B, kernel level: on each non-rebuild step (25 to 50% of steps) it skips the sort, sortBoxData and findBlocks early exit.
- At base: 48.5 + about 8 us minus about 4 empty dispatches at about 1.5 us, so 50 us per skipped step, 12 to 25 us per average step. That is 2.5 to 5% on rf and 2 to 4% on pme and dhfr.
- After nblist's SIMD sortShortList2 (under 10 us): 3 to 6 us per step, under 1.2%.
- gbsa: about 1 to 2%, rate unmeasured.

#### Apple8 (M2) fallback

Nothing in phase A or B needs Apple9. Indirect dispatch is macOS 10.11+, device CAS is Metal 2+, and shared events are macOS 10.14+. The capacity budget is computed from recommendedMaxWorkingSetSize, so on the 8 GB M2 it admits gbsa (0.42 MB) and admits rf, pme and dhfr (36 MB) only if that is under 1% of the M2's working set. Query it and do not assume it. Otherwise the M2 keeps today's synchronous path unchanged. If the 10 us poll costs throughput on the M2's 4 P-cores, use waitUntilSignaledValue for the run-ahead bound on Apple8. It sits K = 2 steps behind the GPU, so its 90 to 110 us wake is off the critical path whenever K x step exceeds the wake time.

#### Memory cost

Worst-case list capacity: gbsa 0.42 MB, rf, pme and dhfr 36 MB, against about 3 to 4 MB today at 1.2x observed. The 8-slot count ring is 96 B and the indirect args are 5 x 12 B. No extra copies of positions.

#### Correctness risks

1. Never read interactionCount directly on the host while run-ahead is active, because sortBoxData zeroes it on rebuild. Read only the ring slots of completed steps.
2. The CAS spill changes which atoms become tiles only when pairs overflow. Forces use fixed-point sums, so they stay exact, and the change affects speed only.
3. hippoNonbonded.cc hard-codes forceArgs indices 7, 17 and 19. They do not change, since no resize happens in this mode, but run TestMetalHippoNonbondedForce anyway.
4. Disable the mode when platformData.contexts.size() > 1.
5. Phase B changes where the rebuild trigger is computed. The forces gate uses a fresh list, so per the review's red flag, check forces against Reference after 50 to 100 MD steps. blockSizeRange is not reset on skipped steps, which only widens the sort's size bins.
6. Every sync path, including getState, CustomIntegrator computeSum and reorderAtoms, still goes through finish(), so host reads stay ordered.
7. Compile the mode in as the default when the capacity rule admits the system. It is not an env knob, per the review.

#### Prototype size

Phase A probe: about 50 lines in MetalNonbondedUtilities.cpp, MetalKernels.cpp and MetalQueue.cpp, 1 to 1.5 hours with one build. Production phase A with the CAS spill and ring: about 150 lines C++ plus 25 lines MSL, 4 to 5 hours. Phase B: about 80 lines C++ plus 30 lines MSL, plus indirect variants of the MetalSort kernels, 4 hours.

#### Feasible tonight

yes

#### First experiment

Lab-only probe build, compiled in and not env-gated.
- Set maxTiles = totalTiles and maxSinglePairs = 20 x numAtoms at init.
- Delete the enqueue in prepareInteractions and the commit, wait and resize in computeInteractions.
- Commit plus encodeSignalEvent at the end of finishComputation, and poll signaledValue for step N-2 before encoding.
- Keep copyInteractionCounts, and at context destruction print how many steps had count[0] > maxTiles or count[1] > maxSinglePairs. It must be 0 for the run to count.
Run the profiler's buffers mode on gbsa and rf single, plus pme as the control, in one lease slot of about 10 minutes.
- Proves the design: the idle gap falls by 15 us or more on gbsa and 30 us or more on rf, and wall us per step falls by 5% or more on both.
- Kills it: the gap falls by less than 8 us. Then the gap is not the wait, and a buffer-boundary cause needs a different fix.

### Design 2: Fused Langevin-middle step: one MSL kernel in which each thread owns a whole constraint cluster (SETTLE water, SHAKE cluster or free atom) and runs Part1, the velocity constraint, Part2, the position constraint and Part3 in registers

#### Native levers

1. Owning the kernel in MSL under platforms/metal instead of compiling the shared langevinMiddle.cc and integrationUtilities.cc as they are.
2. Apple9 dynamic caching: "On-chip register memory is now dynamically allocated and deallocated over the lifetime of the shader according to what each part of the program actually uses" (Apple tech talk 111375, M3 and A17 Pro GPU). A long fused kernel does not pay the peak register allocation of its heaviest phase, the SETTLE solve, for its whole life.
3. Apple9 issues FP32, FP16 and integer instructions in parallel "to a greater degree than ever before" when several SIMD-groups are resident (same talk). In mixed, the int64-emulated df64 IEEE conversions (df64.metal:124-230) can overlap the FP32 constraint math of other SIMD-groups.
4. 32-wide SIMD-groups (WWDC22 10159). Units are sorted by type, so every SIMD-group is uniform (all SETTLE, all SHAKE or all free) and does not diverge.
5. No threadgroup memory and no barriers, just the fused chain per thread.

#### Mechanism

At init, when a LangevinMiddleIntegrator runs with no CCMA constraints, build a unit table from the arrays IntegrationUtilities already uploads: settleAtoms/settleParams, shakeAtoms/shakeParams, and a list of atoms in neither. Sort it SETTLE, then SHAKE, then free. MetalIntegrateLangevinMiddleStepKernel then overrides execute(). Each thread does the following for its unit:
1. Load velm, posq and the fixed-point force for the unit's atoms, and do Part1 (the kick).
2. Apply the velocity constraint: the same SETTLE-vel or SHAKE-vel iteration as integrationUtilities.cc:220 and :489, on the register copies.
3. Do Part2, drawing noise from random[randomIndex + atom]. That is the same per-atom random mapping as today, so the stream is unchanged.
4. Apply the position constraint (SETTLE-pos or SHAKE-pos on the register posDelta).
5. Do Part3 and write velm and posq once. posDelta and oldDelta never touch device memory in this path.
CCMA systems, virtual-site stages (kept as a separate dispatch after), other integrators and double precision keep the shared path. Extension, not in v1: fold the CMMotionRemover's two dispatches in. The fused kernel of step N subtracts the COM momentum that a last-threadgroup reduction (acquire/release atomics) in step N-1 computed. This is exact in intent, because no force reads velocities between updateContextState and Part1.

#### Expected gain

The fused kernel's critical path is the longest per-thread chain, max(water chain, SHAKE chain) plus Part work. Today it is the sum of 5 to 7 serialized launches. Numbers come from the census in lanes/mixed.md.

Single, pme: today about 33 us (54.7 census minus 7 x 5 us of per-buffer overhead, plus 7 x 1.88 us serial floor). Fused, about 12 to 15 us, saving about 18 to 21 us per step:
- pme 2.8 to 3.3%, rf (same 23.5k atoms) 3.6 to 4.2%, dhfr 3.0 to 3.5%.
- gbsa (SHAKE only, 5 to 1 dispatches): 4 x 1.88 us floor plus fewer memory passes, about 8 to 10 us of 293, 2.7 to 3.4%.
- apoa1rf and apoa1pme: about 15 to 20 us, 1 to 1.7%. cellulose and stmv under 1%.

Mixed, pme at base: census kernels 276 us, about 241 us of it real. The fused critical path is max(SETTLE 50.7 + 69.9, SHAKE 44.8 + 53.5) minus overheads plus about 15 to 20 us of Part work, about 125 to 140 us. Savings are about 100 to 115 us of about 863 us per mixed pme step, 11 to 13%. With the mixed lane's c1+c2 in, the chains shrink (SETTLE 26.5 + 51.9, SHAKE 31.9 + 35.5), for about 75 us or 9%. Mixed IEEE conversions per atom fall from about 56 to about 8.

Mixed gbsa: 6 to 9%. Mixed apoa1pme: about 5%.

#### Apple8 (M2) fallback

The kernel uses no Apple9-only feature, so it runs on the M2 unchanged. Without dynamic caching the M2 allocates registers for the heaviest phase. These grids are latency-bound, though (about 8k water threads on rf/pme against a 10-core M2), so occupancy should not bind. Screen on the M2. If it regresses there, gate the fused path on supportsFamily(MTL::GPUFamilyApple9) and keep the shared kernels on Apple8.

#### Memory cost

The unit table is about 16 B per unit: rf/pme about 0.2 MB, stmv about 6 MB. posDelta and oldDelta stay allocated for the other integrators and for getState paths. No new per-step traffic, and roughly 3 to 5 fewer full passes over velm, posDelta and oldDelta per step.

#### Correctness risks

1. Single precision should be bitwise identical to the unfused path, since each atom sees the same operations in the same order and the same random index. Prove it with a posq/velm dump after 100 steps on rf and gbsa. If MathModeSafe contraction differs across inlined statements, expect last-ulp differences and gate on Reference instead.
2. Mixed cannot be bitwise identical, because fewer IEEE round trips means fewer roundings. Run drift.py and constraints.py at 1e-5 and 1e-8 on both chips.
3. It must copy the mixed lane's c1 to c5 constraint math after that lands, or the two diverge. Merge after the mixed bundle.
4. SHAKE clusters and SETTLE waters are disjoint by construction (IntegrationUtilities.cpp:168-290). Assert that at init.
5. Constraint tolerance and convergence behavior must match, and the iteration caps must match the shared kernels.
6. Virtual sites and zero-mass atoms: keep the velocity.w != 0 checks.

#### Prototype size

gbsa-only prototype (SHAKE plus free atoms, single): about 200 lines MSL plus 120 lines C++ (Metal subclass of CommonIntegrateLangevinMiddleStepKernel, MetalKernelFactory entry, unit table), 3 to 4 hours. Full version with SETTLE and mixed: about 550 lines MSL, most of it ported from integrationUtilities.cc:99-580, plus 150 lines C++, 1.5 to 2 days including drift checks.

#### Feasible tonight

no

#### First experiment

Before writing the kernel, run the profiler's counters mode on rf and gbsa, single and mixed, from the existing build with no new code. Take the union of encoder intervals from Part1 to Part3 inclusive, which covers everything the fused kernel would replace. Compare it with that interval's sum minus the longest SETTLE and SHAKE chain.
- Kill: the rf single union is under 15 us, which caps the gain below 2%, and the mixed pme union is under 120 us.
- Otherwise build the gbsa-only single prototype and bitwise-diff posq and velm after 100 steps against base with the same seed. Keep it only if counters mode shows the fused kernel at least 6 us under the 5 kernels it replaces.

### Design 3: Commutative-accumulate hazard classes on a concurrent encoder, with DAG-ordered encoding: fixed-point force writers never barrier each other, bonded and PME spread overlap the neighbor-list chain, and small systems stay serial

#### Native levers

1. MTLDispatchType.concurrent, macOS 10.14+: "If you encode multiple commands that access a single resource, you're responsible for synchronizing the memory operations to that resource" (developer.apple.com/documentation/metal/mtldispatchtype/concurrent). Paired with memoryBarrier(resources:) and memoryBarrier(scope:) (MTLComputeCommandEncoder.hpp:77-78; Apple: memory barriers "ensure the relevant passes finish updating resources before starting the stages of subsequent commands that depend on those resources").
2. Apple's guidance that concurrent dispatch hides "most of the synchronization cost between dependent kernels, as well as fill the ramp up and tail end" (WWDC22 10159, reported in the research brief).
3. Pipeline reflection binding access (MTL::PipelineOptionBindingInfo is already requested in MetalContext::getKernel) to get each argument's read-only or read-write class.
4. The exactness of the split-word fixed-point atomic add (common.metal:57-67; lab 004 found it exact under contention). Integer adds commute bit for bit, so kernels that only atomically add into longForceBuffer impose no order on one another.

#### Mechanism

This builds on the dispatch lane's DISPATCH_MODE=auto; do not redo it. The review found auto cannot remove barriers between force kernels, because they all write forceBuffers.

Add a third access class: accumulate. At kernel creation, mark an argument as accumulate when it is the context's longForceBuffer, or a Born-sum or Born-force fixed-point buffer, and the kernel's source writes it only through ATOMIC_ADD or atomicAdd. That covers computeBondedForces (BondedUtilities.cpp:161-163), computeNonbonded (nonbonded.metal:221-231) and the GBSA force kernels. The hazard rule: accumulate-after-accumulate on the same buffer needs no barrier. Any other pair involving it does, so clear and integration reads still order correctly. gridInterpolateForce does a plain += on forceBuffers when the PME stream is off (pme.cc:351-353), so it stays read-write and keeps its barriers. Barriers are memoryBarrier(resources:) on the conflicting buffers only.

Then reorder encoding within the force section so independent chains interleave: clear, then {findBlockBounds ... findBlocks}, then bonded, then PME spread and FFT, with nonbonded after findBlocks. A resource barrier then lands only where a chain actually depends on the previous kernel. VkFFT keeps its own serial encoder, as the dispatch lane found it requires. Select the mode per system: concurrent when numAtomBlocks is above a measured threshold (large systems), serial otherwise. The barrier-per-dispatch concurrent mode costs 0.45 us more per dispatch than serial (lab 008), which on gbsa would be 20 x 0.45 = 9 us, or 3% lost.

#### Expected gain

The serial barrier cost was measured at about 5% on large systems (counters mode 0.960, 0.940 and 0.944). The accumulate class also lets bonded run under the neighbor-list chain. bonded is 11 to 16% of large tests and findBlocks 13 to 25%, but they compete for the same cores, so only tails and low-occupancy phases are recovered.
- Single, kernel-to-step estimate: apoa1pme 2 to 5% (35 to 90 us), cellulose 3 to 5% (190 to 320 us), stmv 3 to 5%, apoa1ljpme 2 to 4%, apoa1rf 2 to 4%.
- pme and dhfr 0 to 2%. gbsa and rf 0, since they stay serial by rule.
- Mixed: the same microseconds, so 1.5 to 4% on the large tests.
This stacks with the fused integrator, which removes a chain of the barriers.

#### Apple8 (M2) fallback

Concurrent dispatch and resource barriers are available on every Apple family since macOS 10.14. On the M2 the 10 cores fill sooner, so tails matter less. Keep serial on Apple8 unless an M2 screen of apoa1pme and apoa1rf shows 3% or more, and the threshold is per device.

#### Memory cost

None on the GPU. Host: one access-class vector per kernel.

#### Correctness risks

1. A misclassified kernel races silently. A plain += on longForceBuffer overlapping atomics loses contributions, well inside the gate's third-digit tolerance. Mark accumulate only from the kernel source, never from a name list alone. Then diff forces bitwise against serial on rf, gbsa and apoa1rf, which must match exactly because the adds are integer.
2. energyBuffer is a per-thread float read-modify-write (energyBuffer[GLOBAL_ID] +=) and stays read-write. Compute-energy steps therefore keep more barriers.
3. If the PME stream is ever enabled, interpolate becomes atomic but runs on another queue; keep the cross-queue event.
4. Whether memoryBarrier(resources:) waits only on writers of those resources or on every prior dispatch is undocumented (research brief, open question). If it is a full barrier, the interleaved chains run in lockstep and the gain falls toward the low end.
5. Compile it in as the default for the admitted sizes, per the review.

#### Prototype size

On top of the dispatch lane's auto branch: about 40 lines for the accumulate class and source scan, plus about 30 lines to reorder the force-section encode, 2 to 3 hours. Without that branch, about 200 lines.

#### Feasible tonight

yes

#### First experiment

On the dispatch lane's auto build, add only the accumulate exemption for longForceBuffer with source-verified kernels. Run DISPATCH_STATS=1 once on apoa1pme, cellulose and apoa1rf and read barriers per dispatch.
- Continue only if barriers drop by 25% or more against plain auto.
- Then run counters-free buffers mode on apoa1pme and cellulose against serial, bitwise-diff the forces on apoa1rf, and keep it only at 3% or more on apoa1pme or cellulose.

### Rejected

- A Metal 4 port (MTL4CommandQueue, command allocators, argument tables, residency sets). Lab 008 measured 2.16 us of GPU time per dependent dispatch with an MTL4 encoder and intra-pass barriers, against 1.88 us for a classic serial encoder, at the same 0.10 us of host encode. Metal 4 barriers are stage-scoped (barrierAfterEncoderStages), so they are no finer than a classic concurrent encoder's. Argument tables and allocator reuse only cut host time, which is off the critical path once design 1 removes the wait. Keep MTL4CounterHeap and CommitFeedback for profiling only.
- Residency sets (macOS 15+, Apple6+). The platform binds every buffer with setBuffer and never calls useResource, so there is no residency overhead to remove.
- Untracked hazards (ResourceHazardTrackingModeUntracked, MTLResource.hpp:84). They save driver-side CPU tracking only. Across encoders, Metal's tracked resources are what let consecutive encoders overlap in the profiler's counters mode, so untracking would also throw that away.
- Indirect command buffers recorded once and replayed. Host encode is 0.112 us per dispatch (lab 008), about 2 to 5 us per step, and it is hidden behind run-ahead once the wait is gone. MTLIndirectComputeCommand has no setBytes, so the box vectors, random index and step scalars would have to move into buffers. Nothing shows an ICB lowers the GPU cost of a dependent dispatch. Their one real use, GPU-chosen execution, is served more simply by per-kernel indirect dispatch in design 1. executeCommandsInBuffer with an indirect range (MTLComputeCommandEncoder.hpp:75) stays available if the multi-kernel CCMA path ever needs it (FAHBench, not benchmark.py).
- A persistent megakernel for the whole step, with a grid-wide barrier. MSL defines barriers only at threadgroup and SIMD-group scope, and Metal offers no cooperative-launch forward-progress guarantee, so a grid-wide spin barrier can deadlock.
- A finer "no blit" unified-memory change. It is already in place: every MetalArray is MTLStorageModeShared (MetalArray.cpp:53) and download() is finish() plus memcpy. The remaining waste is the pinned copy in copyInteractionCounts, which design 1 repurposes as the count ring.
- Replacing finish()'s waitUntilCompleted (90 to 110 us wake) only matters for getState and CustomIntegrator syncs, not the benchmark step loop. The research workloads note covers it.
- A poison-and-replay overflow scheme, with integration gated off by indirect dispatch and the host replaying steps. It needs integrator-specific replay inside Integrator::step(n) and breaks the n-steps contract. The hard-bound capacity in design 1 makes overflow impossible for the systems where the gap matters.
- An all-pairs fallback kernel for overflow. The gbsaObc.cc cutoff path has no no-list variant (gbsaObc.cc:162-170), so every list consumer would need a new kernel.
- A second MTLCommandQueue for PME. It is a real native lever, but the pme lane owns it (the MetalDisablePmeStream flip), so I left it out here.

## Area: Reciprocal space PME on the Metal platform: gridSpreadCharge, VkFFT forward and inverse, reciprocalConvolution, gridInterpolateForce, the PME atom sort, and how the chain is scheduled against direct space (same serial encoder today; the second PME queue is off by default through MetalDisablePmeStream).

### Current cost

All numbers are Metal single on the M3 Ultra. apoa1pme, profiler counters mode on 6df2b8bcb (profiler.md, pme.md 20:20Z; step 1707 to 1772 us): gridSpreadCharge 429 us (fixed point), finishSpreadCharge 18, VkFFT 58 each way (116), gridInterpolateForce 43, reciprocalConvolution 15, plus findAtomGridIndex and the sort every other step. Host-clock group split (pme.md 22:25): on apoa1pme reciprocal minus empty is about 1.0 ms and direct minus empty about 1.1 ms, and all minus empty is 2.2 ms. On pme it is 0.24 ms reciprocal and 0.30 ms direct, 0.51 ms together. So the chain runs strictly in series with direct space today. After the pme lane's two commits (71a602b43 float atomics on Apple9, screened at 1.104 pme, 1.159 apoa1pme and 1.172 apoa1ljpme; 17929e631 nosort, screened at 1.034 pme and 1.022 apoa1pme), my estimate of the residual chain is spread about 204 us (1772 x (1 - 1/1.159) = 243 us saved out of 447 for spread plus finish), FFT 116, conv 15, interp 43. That is about 378 us of an estimated 1496 us apoa1pme step (25%). On pme it is about 160 to 180 us of an estimated 560 us step (29 to 32%). apoa1ljpme runs two chains, so about 35% (inference from the 1.172 float gain, which saved about 350 us). On stmv spread was 4.8 ms of 16.3 ms fixed point, about 2.0 ms after float at lab 011's 2.44x kernel ratio. Lab 011 (HEAD-NOTE, like-for-like GPU clock, 98^3): VkFFT on Metal matches VkFFT on OpenCL (0.067/0.064 ms), and MPSGraph FFT is 4 to 7x slower.

### Why today's code is OpenCL-shaped

1. The whole reciprocal chain is encoded into the same serial compute encoder as bonded and nonbonded (MetalQueue::getEncoder keeps one encoder per command buffer). That is OpenCL's in-order queue semantic. Every PME dispatch waits for the one before it, and the chain has no data dependence on the neighbor-list build or on nonbonded until the final force write.
2. gridInterpolateForce does a non-atomic += into the shared 64-bit fixed-point force buffer (pme.cc, the non-USE_PME_STREAM branch). That write is safe only because everything is serialized, and it is the one edge that ties PME to direct space.
3. clearAutoclearBuffers clears pmeGrid1 in the same clearSixBuffers dispatch as longForceBuffer and energyBuffer (ComputeContext.cpp:224). Posq is written by integration in the same encoder that later holds findBlocks. So even if Metal's hazard tracking were allowed to schedule PME independently, the chain would inherit false dependencies on the whole neighbor-list pass.
4. The only overlap mechanism is a CUDA-stream clone. The second queue (off by default, MetalPlatform.cpp:137) costs two extra commits per step through MetalEvent::enqueue and turns the interpolation writes into emulated 64-bit atomics. FAH cores force it off.
5. The spread's launch shape is CUDA-era: PME_ORDER threads per atom, each recomputing the full 3D B-spline, capped at numThreadBlocks = 12 x 60 blocks of 64. That is 46080 threads, 768 per core, below Apple's 1K to 2K per core guidance (WWDC22 10159, quoted in the research brief). It also uses 64-bit fixed-point atomics because OpenCL 1.2 on Apple has no float atomics. 71a602b43 fixes the atomics on Apple9, but the launch shape is unchanged.
6. VkFFT is appended as a black box with a separate convolution pass between the two transforms: 7 grid passes where 5 are enough.

### Design 1: PME as its own hazard-tracked compute pass, overlapped with the neighbor-list build, bonded and nonbonded on one queue

#### Native levers

(a) Metal's automatic hazard tracking on an MTLCommandQueue. Apple, Resource synchronization (developer.apple.com/documentation/metal/resource-synchronization): "By design, GPUs can run multiple commands in parallel". Metal synchronizes only tracked resources bound directly to an encoder, and "Resources you create from an MTLDevice instance default to tracked". MTLHazardTrackingMode.tracked (developer.apple.com/documentation/metal/mtlhazardtrackingmode/tracked): Metal will "Delay write operations until all previous read operations finish" and "Prevent subsequent commands from running until write operations finish". So only commands that conflict are held back. MetalArray.cpp:55 allocates every buffer with device->newBuffer(StorageModeShared), which is tracked by default. (b) Pass-level ordering: the MTLFence doc describes synchronization as ordering memory operations "between GPU passes", so the pass (encoder) is the unit to split on. (c) Measured on this machine: the profiler's counters mode (one encoder per dispatch) shows encoder intervals whose union is 10 to 20% below their sum, and that mode runs apoa1pme 4%, cellulose 6% and stmv 5.6% faster despite 31 encoder boundaries. So the Ultra does overlap independent passes. (d) No MTLEvent, no second queue, no extra commit. OpenCL's in-order queue on Apple cannot express this.

#### Mechanism

Split the step into passes so that the PME chain depends only on data written before the neighbor-list build.
1. At the start of MetalNonbondedUtilities::prepareInteractions, end the current encoder. This splits pass B1 (previous integration plus clears, the last posq writer) from pass B2 (sortBoxData, findBlocks, sortShortList2 and the rest). One line, plus a public MetalQueue::splitPass() wrapping the private endEncoding (4 lines).
2. Override MetalCalcNonbondedForceKernel::execute to call splitPass() before and after CommonCalcNonbondedForceKernel::execute. The reciprocal chain then sits alone in its own encoder P, ahead of the bonded plus nonbonded encoder D in the same command buffer.
3. Remove the false dependencies:
- Take pmeGrid1 (or pmeGrid2 in fixed point) out of the autoclear list, and clear it with the compute clearBuffer as the first dispatch of P.
- Add a define (for example PME_FORCE_ARRAY) to gridInterpolateForce so it stores a real4 per atom into a new pmeForce array instead of +=-ing forceBuffers. One writer per atom, no atomics.
- Route gridEvaluateEnergy to pmeEnergyBuffer when energy is requested. The existing addEnergy kernel already does this for the stream path.
4. Fold pmeForce into forceBuffers with the addForces kernel that pme.cc already has. Register it as a ForcePostComputation guarded by recipForceGroup, so it runs after nonbonded, before virtual-site distribution, in the serial encoder where plain += stays safe.
5. LJPME: give the dispersion interpolation its own real4 slot, so the fold converts Coulomb and dispersion separately. The integer force sum is then bitwise identical to base. When recommendedMaxWorkingSetSize allows, also give dispersion its own two grids, so the Coulomb and dispersion chains become two independent passes that overlap each other as well.

What P touches: reads posq, charges or sigmaEpsilon, pmeAtomGridIndex and the moduli; writes pmeGrid1/2 and pmeForce (VkFFT binds its own tracked buffers). Neither B2 nor D reads or writes any of these, so Metal's tracker lets P run beside findBlocks, sortShortList2, computeRange, bonded and nonbonded. The fold is the only join. All of this is enabled by a commonInitialize flag (the same pattern as sortPmeAtoms), so OpenCL, CUDA and HIP compile unchanged code.

#### Expected gain

Kernel level: no kernel gets faster. The gain is the hidden fraction h of the chain, minus the cost of three encoder boundaries plus one fold dispatch. My estimate of that cost is 10 to 25 us: the profiler's 1.33x counters-mode penalty on pme works out to about 8 us per encoder boundary including timestamp sampling, and addForces on 92k atoms moves about 3.7 MB, about 5 to 10 us.

Where idle cores exist, from the profiler:
- the 50 to 75% of steps that rebuild the neighbor list (findBlocks 280 us on dhfr size, 450 to 520 us on apoa1)
- sortShortList2 (12 threadgroups of 64 for 48.5 us every step on dhfr size, so about 80% of the 60 cores idle)
- computeRange (1 threadgroup, 121 us per call on apoa1ljpme)
- the tail of computeNonbonded
- the 56^3 FFT dispatches on pme, which are too small to fill 60 cores

Per test, taking h = 0.3 to 0.6 of the post-float chain:
- apoa1pme: 378 us chain, saves 113 to 227 us minus about 20, 1.07 to 1.15x.
- pme and amber20-dhfr: 160 to 180 us chain, saves 50 to 108 us minus 20, 1.05 to 1.17x.
- apoa1ljpme: about 700 us over two chains that can also overlap each other, 1.10 to 1.24x.
- cellulose and stmv: 1.06 to 1.14x (stmv chain about 3 to 3.5 ms of about 13.8 ms after float, inference).
- rf, apoa1rf and gbsa: unchanged, because the flag is off without PME.

Mixed precision gains the same microseconds on longer steps, so about 0.75x the single excess on pme. The upper ends assume nblist's sortShortList2 and computeRange fixes have not already removed those idle windows. Measure this on top of them.

#### Apple8 (M2) fallback

The mechanism is universal, since hazard tracking and multiple passes work on every family. The M2's 10 cores are saturated by computeNonbonded, though, so the hidden fraction will be small while the 10 to 25 us overhead is not. That is about 0.9% of the M2's 1.69 ms pme step. Key the flag on the device (supportsFamily(MTL::GPUFamilyApple9), or getMultiprocessors() >= 16) and keep the M2 on today's serial path until an M2 screen shows no loss beyond 1%. Memory: pmeForce is 16 B per atom (32 B for LJPME): 1.5 MB on apoa1, 17 to 34 MB on stmv. Separate LJPME dispersion grids (2 x grid x 8 B, up to about 15 MB at apoa1 size) only when the working set allows, never on an 8 GB device.

#### Memory cost

pmeForce: 16 B per atom, or 32 B per atom for LJPME (1.5 to 3 MB on apoa1pme and apoa1ljpme, 17 to 34 MB on stmv). Optional second grid pair for LJPME dispersion: 2 x dispersion grid points x 8 B (about 15 MB at 98^3), gated on recommendedMaxWorkingSetSize. The autoclear list shrinks by one entry. Nothing else.

#### Correctness risks

Low for physics. Tracked hazards make Metal enforce every real dependency, so a missed edge costs overlap, not correctness. The design adds no barriers of its own to get wrong.
- Forces are bitwise identical to base with DeterministicForces=true, because the same float values reach realToFixedPoint and integer adds commute. That gives a strict gate: a bitwise force diff against 6df2b8bcb plus 71a602b43 on pme, apoa1pme and apoa1ljpme.
- Risks to check:
(1) the fold must honor force groups, as SyncQueuePostComputation does, or getState(groups) with reciprocal excluded double counts;
(2) energy steps put gridEvaluateEnergy in conflict with nonbonded on energyBuffer unless routed to pmeEnergyBuffer (slower, not wrong);
(3) the flag must be exclusive with usePmeQueue and the CPU PME path;
(4) virtual sites need the fold to run before distributeForcesFromVirtualSites, and post computations already do;
(5) any future lane that switches the direct-space encoder to concurrent dispatch must still treat pass P as external;
(6) plugins that reuse CommonCalcNonbondedForceKernel inherit the flag only through Metal.
- Proving overlap happens needs timestamps. Identical forces cannot show it.

#### Prototype size

Probe (lab only, timing only): about 25 lines (splitPass 4, execute wrapper 8, prepareInteractions split 1, grid clear moved 6, a PME_LAB_NOINTERP knob 3), about 1 hour to code and build. Full candidate: about 90 lines (common flag and array 20, interp define 8, fold post-computation 25, LJPME split slots 15, energy routing 10, Metal wrapper 12), about 3 hours to code, then the gate.

#### Feasible tonight

yes

#### First experiment

One lease on the Ultra, one lab build with three arms: A, serial with interp skipped (PME_LAB_NOINTERP); B, the split-pass probe with interp skipped; C, the unmodified path with MetalDisablePmeStream=false (zero code: the existing second queue, which the review asked pme to screen anyway). Tests pme, apoa1pme and apoa1ljpme, 2 x 15 s interleaved. Also run one buffers-mode timestamp pass of arm B, with the profiler lane's GpuProf hooks or MTLCounterSampleBuffer stage-boundary samples at encoder start and end, to confirm that pass P's GPU interval actually overlaps B2 and D. Kill the design if B/A is below 1.03 on both apoa1pme and pme, or if the timestamps show P starting only after D ends. If C beats B, move the chain to the second queue with the same fold (no atomics) instead.

### Design 2: Occupancy-friendly tile-privatized spread with native 32-bit integer threadgroup atomics (Apple9)

#### Native levers

(a) Threadgroup atomic_int and atomic_uint fetch_add are single native operations on every Apple family. MSL 4.1 spec 6.15/6.16 lists threadgroup atomic functions since Metal 1 and 2. By contrast, atomic_float add and sub work in threadgroup memory only from MSL 4.1 (spec: "Metal 4.1 and later add atomic_float support for atomic add and sub in threadgroup memory"), and the review says to keep MSL 4.1 out. (b) Apple9 Dynamic Caching: threadgroup memory is a cache that "can utilize the entire span of the on-chip memory, and even overflow into main memory" (Apple tech talk 111375). Occupancy is managed dynamically, so a small tile lets several threadgroups share a core. (c) 32 KB threadgroup memory per threadgroup on Apple7 and up (Metal Feature Set Tables, limits table). (d) SIMD reductions (simd_max, simd_sum) on Apple7 and up (Feature Set Tables) set the per-chunk fixed-point scale without a threadgroup pass. (e) Device float atomics on Apple9 for the flush (Feature Set Tables list floating-point atomics from Apple7. The Apple9 hardware path is measured in lab 004: 0.34 ms on the M3 Ultra against 190.8 ms on the M2).

#### Mechanism

This changes the pme lane's lab kernel gridSpreadChargeTiled (a 28 KB float tile with CAS or MSL 4.1 atomic_float, 256 atoms, one group per core) in three ways.
(1) The tile is int32 fixed point, filled with native atomic_fetch_add_explicit on threadgroup atomic_int, with no CAS and no MSL 4.1. The scale is 2^(30 - ceil(log2(B))). B = 0.215 x the sum of |q| over the chunk, from simd_sum, where 0.215 is about the largest order-5 B-spline weight product (0.599^3). A 128-atom water chunk gives B of about 180 and a scale of 2^22, so each quantization step is 2.4e-7 absolute. That is comparable to a float atomic's rounding on grid values of order 1, and overflow is impossible by construction.
(2) Chunks are 128 atoms with a tile of at most 3072 points (12 KB), so two or three threadgroups fit per core instead of one. The existing bounding-box pass stays, and chunks that do not fit fall back to direct device atomics, as today.
(3) The flush converts each nonzero tile point to float and issues one device atomic_float add on Apple9. Summing within a tile is order-independent. On Apple9 this replaces about 125 device atomics per atom with one per touched tile point. At 1.11 A spacing and 0.136 atoms per cell, 128 atoms touch about 11.8^3 = 1640 points (review: 256 atoms need about 4900) against 16000 contributions, so device atomics drop 5 to 10x. Selected through a commonInitialize flag tied to !useFixedPointChargeSpreading, never by getenv.

#### Expected gain

The kernel gain is bounded by how much of the spread is device-atomic throughput. That is unmeasured: the pme lane's PLAIN and NOWRITE arms are queued. If atomics are 35 to 50% of the float spread (the review's threshold), the tile removes most of that and adds tile init, the bounding-box pass and the flush. My estimate is 30 to 50% off the kernel. Whole step, from post-float shares:
- apoa1pme: spread about 204 us of about 1496 (13.6%), 1.04 to 1.07x.
- apoa1ljpme: two spreads, 1.06 to 1.10x.
- stmv: spread about 2.0 ms of about 13.8 ms, 1.05 to 1.08x.
- pme and dhfr: spread about 8% of the step, 1.02 to 1.04x.
If design 1 lands, part of the spread is already hidden, so the combined gain is lower than the product.

#### Apple8 (M2) fallback

Off on Apple8. The pme lane's M2 screen (pme.md 21:03Z) put the float-tile kernel at 0.80x on pme, apoa1pme and apoa1ljpme, with MSL 4.1 atomic_float no faster than CAS. Apple8 keeps the fixed-point device spread. A deterministic Apple8 variant is possible: flush int tile sums into the 64-bit fixed-point grid through an exact shift to 2^32 scale, giving bitwise-reproducible sums in any order. Screen it only if the Ultra shows the int tile wins, because the M2 result suggests threadgroup atomic throughput itself, not the CAS, is the M2 limit.

#### Memory cost

No device memory. 12 KB of threadgroup memory per threadgroup instead of 28 KB, which is the point of the change.

#### Correctness risks

(1) Fixed-point quantization at 2^-22 to 2^-24 changes rounding against the float spread. Gate rel|dF| against Reference and against DeterministicForces=true on the same build, and rerun three times, as the review asks for float spreading.
(2) The per-chunk scale must count only charged atoms, and LJPME's 8 sigma^3 epsilon charges need their own bound. They are about 0.1, so the scale gets finer, not coarser.
(3) Periodic unwrap of the bounding box across the boundary (already handled in the lab kernel, and correct at roundoff on the M2).
(4) A chunk whose atoms have drifted apart between reorders falls back to device atomics. Log the fallback fraction, since the review estimates fallback could be common at 256 atoms.

#### Prototype size

About 40 lines changed in the pme lane's existing gridSpreadChargeTiled (tile type, scale, chunk size, flush) plus the commonInitialize flag (about 10 lines). About 1.5 hours.

#### Feasible tonight

yes

#### First experiment

Cheapest first: read the pme lane's queued Ultra arms, PLAIN and NOWRITE against the float spread, and tiled41 (Studio ticket 41058). If PLAIN is less than 35% faster than the float spread, or tiled41 is below 0.9x of float on the Ultra, kill this design without building anything. Otherwise build the int tile variant as one more arm in the pme lane's next lease, on apoa1pme and apoa1ljpme, 2 x 15 s, and log the tile-fit fraction.

### Design 3: Fused spectral pass: forward last-axis FFT, convolution and inverse first-axis FFT in one dispatch through VkFFT's convolution mode

#### Native levers

This design is mostly an algorithmic lever. The native part is small: VkFFT's Metal backend emits MSL at runtime and appends to our encoder (MetalFFT3D.cpp). Its configuration supports performConvolution, where the kernel multiply happens in frequency space inside the last forward axis and the first inverse axis (libraries/vkfft/include/vkFFT.h:236, kernel buffers as MTL::Buffer** at :161). omitDimension cannot drop the R2C axis 0 and does not combine with convolutions (vkFFT.h:180). That rules out swapping one axis for a hand-written MSL kernel inside VkFFT. The only other native piece is a tiny MSL generator kernel that writes the real eterm coefficients as a complex kernel buffer from the existing reciprocalConvolution math, re-run only when the box changes.

#### Mechanism

Build a second VkFFT application with performConvolution = 1, coordinateFeatures = 1, R2C, and a kernel buffer the size of the half-complex grid. The kernel is eterm (with the k = 0 term zeroed, plus the LJPME variant). A generator dispatch refreshes it when the host sees box vectors change (barostat). On steps without energy, one VkFFTAppend replaces forward FFT, reciprocalConvolution and inverse FFT. On energy steps, keep the current unfused path, because gridEvaluateEnergy needs the forward-transformed grid before the multiply. The grid goes from 7 passes (3 + 1 + 3) to 5, and one dispatch disappears.

#### Expected gain

The kernel-level saving is 2/7 of (FFT + conv). apoa1pme: (116 + 15) x 2/7 = 37 us of about 1496 us, 1.025x. apoa1ljpme: two grids, 1.03 to 1.04x. pme and dhfr: the 56^3 transforms are latency bound, so saving 1 to 2 dispatches is about 10 to 15 us of 560, 1.01 to 1.02x. stmv: about 1.02 to 1.03x. That is below the 3% keep bar except perhaps apoa1ljpme. If design 1 lands, the FFT is off the critical path on the large systems and this is worth close to zero there.

#### Apple8 (M2) fallback

Platform-agnostic: VkFFT runs the same on Apple8 (lab 011: Metal VkFFT is 5 to 11% ahead of OpenCL VkFFT on the M2). Energy steps and double precision keep the unfused path.

#### Memory cost

One half-complex kernel buffer per grid: 3.84 MB at 98^3 single, doubled for LJPME. On the M2, scale the gate with recommendedMaxWorkingSetSize.

#### Correctness risks

(1) VkFFT's convolution mode with R2C, inverseReturnToInputBuffer and the Metal backend together has not been exercised in this tree. The kernel buffer layout and normalization convention must match the unfused path. Verify against the unfused chain at roundoff (lab 011's gate ran at 0.3 ppm).
(2) A stale kernel after a box change would give silently wrong forces. Compare box vectors on the host every step and regenerate.
(3) The energy-step fallback makes energy and force steps take different code paths. Both need the Reference gate.

#### Prototype size

About 60 lines (second VkFFT app 20, generator kernel 20, box-change check and dispatch selection 20). 3 to 4 hours, most of it in VkFFT configuration.

#### Feasible tonight

no

#### First experiment

Off the GPU queue: on the M2, build a standalone harness from lab 011's captured apoa1pme buffers (experiments/011-pme/captures) that runs the fused VkFFT app against the unfused one. Check agreement under 1 ppm and time both on the GPU clock. Kill if the fused transform saves less than 25% of (FFT + conv) or does not agree. Only then spend an Ultra lease slot.

### Rejected

- Hand-written MSL FFT replacing VkFFT: rejected. Lab 011 shows VkFFT on Metal already at OpenCL parity (0.067/0.064 ms at 98^3). The research brief puts it at roughly 350 GB/s effective, so a Stockham rewrite has at most about 2x to find on 116 us, about 4% of apoa1pme, and less once design 1 hides the chain. arXiv 2603.27569's 138 GFLOPS MSL radix-8 result is 1D only. It would also need mixed radix up to 13 to keep the grid Reference uses (pme.md: a grid change fails the gate).
- MPSGraph FFT: 4 to 7x slower than VkFFT (lab 011 HEAD-NOTE), so the MPS rule excludes it.
- simdgroup_matrix DFT stages (Apple7+, Feature Set Tables): a 98-point DFT as a matrix product costs about 38k MACs per line against VkFFT's radix-7 butterflies. No win at PME sizes.
- Fused spread plus FFT, or inverse FFT plus interpolation: every FFT axis needs the complete grid, so each fusion needs a device-wide barrier inside a kernel. Metal has no grid-wide sync, and MSL 4.1 acquire and release atomics would give a last-threadgroup-reduces pattern, not a pipeline.
- Gather spreading: 19x slower on the Ultra, 34x on the M2 (lab 011).
- MSL 4.1 threadgroup atomic_float: the review says keep 4.1 out, and on the M2 it was no faster than CAS (pme.md 21:03Z). Design 2 uses native int atomics instead.
- A concurrent-dispatch encoder with memoryBarrier(resources:) to overlap PME inside one pass: the barrier docs say the relevant passes finish before later commands start, with no per-chain scope, and the brief found no Apple statement that it waits only on the listed resources' writers. Interleaved PME and direct chains would run in lockstep. Separate passes with tracked hazards (design 1) avoid that.
- MTL4CommandQueue with explicit barriers: Metal 4 drops hazard tracking entirely (MTLHazardTrackingMode doc: \"Metal doesn't apply hazard tracking to commands you submit to an MTL4CommandQueue\"). That would mean rewriting submission and residency for the whole platform for a benefit design 1 gets on today's queue.
- Indirect command buffers for the PME chain: the host is not on the critical path (idle gap 0.7% on apoa1pme), so there is nothing to save.
- Imageblocks in compute: same 32 KB explicit limit as threadgroup memory (Feature Set Tables) and no atomics advantage.
- 64-bit atomic add: does not exist. Apple9's \"full set\" is min and max only (Feature Set Tables footnote 7, MSL 4.1 spec 6.16.4.6).
- Float atomics on Apple8: measured losing 3 to 7% (pme.md), and the M2 uses a CAS path (lab 004).
- PME atom sort: already removed on Metal by 17929e631. Nothing native left to add.
- SIMD-cooperative gridInterpolateForce (5 lanes per atom with shuffle reduction): the kernel is 43 us, about 3% of apoa1pme, so even a 2x kernel is about 1.5% of the step, and design 1 hides it anyway.
- Changing grid sizes or alpha: changes the discretization against Reference and fails the gate.

## Area: computeBondedForces, LangevinMiddle integration, SHAKE and SETTLE, and the mixed-precision df64 chains in the Metal platform (base 6df2b8bcb)

### Current cost

Bonded, from the profiler lane's counters run (p1, Metal single, M3 Ultra) as summarized in review-20260924T2120Z.md section 3: computeBondedForces takes 185 us/step on apoa1rf (16%), 254 us on apoa1pme (14%), 955 us on cellulose (15%), about 11% of stmv (about 1.8 ms of 16.3 ms) and of apoa1ljpme (about 260 us), and 6 to 7% of pme and dhfr (about 40 us). Workload from the apoa1 kernel dump (experiments/005-real-program-census/dumps/apoa1pme/007.body.cl): 11,428 bonds, 52,678 angles, 99,628 torsions and 73,902 exceptions, plus 218,698 PME exclusion pairs in PME only. That is 727,206 atom slots in RF and 1,164,602 in PME, so 2.18M and 3.49M fixed-point 64-bit adds, each one to two 32-bit atomics (common.metal atomicAdd). The implied rate is 11.8 G adds/s on apoa1rf and 13.7 G on apoa1pme. The atomics lane's microbenchmark measured about 37 G emulated adds/s at pure throughput. The 1.31M extra adds that PME brings cost 69 us (254 minus 185). Arithmetic is negligible: about 240k terms at a few hundred flops each. So I infer the kernel is bound by atomic count and contention, which the first experiment below must confirm. Integration and constraints, from the mixed lane's census (one command buffer per kernel, so each kernel carries about 5 us of overhead, pme): single SETTLE pos 10.8, SETTLE vel 8.8, SHAKE pos 7.7, SHAKE vel 6.4 and LangevinMiddle Part1+2+3 21.0 us, which the review puts at 30 to 55 us per pme step. Mixed base: 69.9, 50.7, 53.5, 44.8 and 57.2 us, 276 us in total. Mixed minus single is 234 us on pme, 126 on gbsa and 283 on apoa1pme. SHAKE takes about 50 us in mixed from 2.5k to 92k atoms, so a single thread's df64 dependency chain bounds it. With the mixed lane's c1+c2 applied: 51.9, 26.5, 35.5, 31.9 and 55.3 us.

### Why today's code is OpenCL-shaped

Bonded (platforms/common/src/BondedUtilities.cpp, compiled unchanged for Metal; MetalBondedUtilities.h adds nothing). The kernel assigns one thread per term in a grid-stride loop capped at 12 x cores threadgroups (MetalContext.cpp numThreadBlocksPerComputeUnit = 12, still marked METAL-TODO). It issues 3 ATOMIC_ADDs per atom per term into the long force buffer. Its accumulation model assumes CUDA's native 64-bit atomicAdd. Apple GPUs have none (MSL 4.1 6.16.4.6 defines only atomic_max and atomic_min for atomic_ulong, and the atomics lane's compile test confirms it), so each add becomes a returning 32-bit atomic plus a conditional second one. Terms arrive in topology order, so neighbouring lanes of a SIMD group hit the same atoms (the torsions around one bond, for example). Same-address atomics inside a SIMD group serialize. Nothing uses threadgroup memory or SIMD reductions to combine contributions before they reach device memory. Integration (CommonIntegrateLangevinMiddleStepKernel::execute plus MetalIntegrationUtilities::applyConstraintsImpl) runs 7 dependent dispatches per step: Part1, SETTLE vel, SHAKE vel, Part2, SETTLE pos, SHAKE pos and Part3, plus 2 for the CM motion remover. This is the OpenCL and CUDA stream model of one kernel per stage. SETTLE and SHAKE work on disjoint atoms, yet they run back to back, so their latency chains add instead of overlapping. Between stages, velm, posDelta and oldDelta round-trip through device memory. In mixed precision every one of those loads and stores runs df64_from_ieee or df64_to_ieee (df64.metal:124-230), integer-heavy 64-bit IEEE packing and unpacking. I count about 9 double4 loads and 7 double4 stores per atom per step, roughly 64 conversions, and the fused design needs 8. The serial encoder also adds an implicit barrier of about 1.88 us after each dispatch (lab 008).

### Design 1: Chunked atom-owner bonded kernel: threadgroup-memory gather, one atomic per atom per chunk, bit-identical to base

#### Native levers

Threadgroup memory used as a per-threadgroup scatter pad. The limit is 32 KB per threadgroup on Apple8 and Apple9 (Metal Feature Set Tables, May 2026, verified in research/2026-09-24-apple-gpu-metal-brief.md section 2). On Apple9, threadgroup memory is itself cached on chip ('flexible on-chip memory ... threadgroup and tile memory, making that a cache too', Apple tech talk 111375, fetched tonight), so a 12 KB pad no longer caps occupancy as hard as it would on the M2. threadgroup_barrier and plain 32-bit device atomics exist on every family (MSL spec 6.16.4). The chunk size comes from MTLDevice maxThreadgroupMemoryLength, and a function constant (MSL spec 5.8.1, [[function_constant]]) specializes the pad size per device. No Apple9-only feature is needed, and no native 64-bit add is needed, since there is none.

#### Mechanism

Override initialize and computeInteractions in MetalBondedUtilities. MetalContext holds a MetalBondedUtilities* and calls through that type (MetalContext.h:448 and :498, MetalKernels.cpp:75), so name hiding works. The only common edit is private to protected in BondedUtilities.h, which changes no generated code, so OpenCL is unaffected. At init the host sorts every bonded term (force f, index i) by owner block (min atom index / 32), then by f, and cuts the list into chunks of 256 terms. For each chunk it records the unique atoms it touches (typically 45 to 80) and a CSR list of slot positions per local atom as ushorts. Everything goes into one packed plan buffer, which keeps the kernel under Metal's 31-buffer limit. Each thread loads its (f, index), runs the unchanged generated snippet from the shared .cc files (so custom and long-tail bonded forces keep working), and writes force1..forceN as packed_float3 to pad[lid*4+k], a 12 KB pad. After threadgroup_barrier, each thread takes ceil(U/256) of the local atoms. For each one it sums realToFixedPoint(pad[s]) over the atom's slots in 64-bit integer registers, then issues one split-word atomicAdd per component into the long force buffer. Fixed-point addition is exact mod 2^64 and the per-slot conversions match base's, so the force buffer is bitwise identical to base whatever the order. Energy and energyParamDerivs keep their per-thread slots, and a group mask zeroes the slots of excluded force groups. A force with more than 4 atoms per term, double precision, or a plan past the argument limit falls back to the shared kernel.

#### Expected gain

Atomic count for apoa1 drops from 2.18M to about 150k fixed-point adds in RF (roughly 14x) and from 3.49M to about 450k in PME (about 8x; the three exclusion pairs per rigid water reduce only 2x). If bonded time follows atomic count, as the 11.8 to 19 G adds/s rates suggest, the kernel falls to 20 to 30% of today. Single, from the measured shares: apoa1rf saves 130 to 148 us of 1144.5 (1.13 to 1.15x), apoa1pme 178 to 203 us of 1772 (1.11 to 1.13x), apoa1ljpme about 185 to 210 us of 2391 (1.08 to 1.10x), cellulose 670 to 765 us of 6371 (1.12 to 1.14x), stmv 1.25 to 1.43 ms of 16.3 ms (1.08 to 1.10x), pme and dhfr about 28 to 32 us (1.045 to 1.05x), rf about 1.02 to 1.03x, and gbsa flat. Mixed precision saves the same microseconds on longer steps, about 0.8 times the relative gain. If the probe shows the kernel only half atomic-bound, halve these. This stacks with the force-words lane, which targets the nonbonded atomics, not bonded.

#### Apple8 (M2) fallback

The same kernel runs on the M2: 32 KB threadgroup limit, integer atomics only, no float atomics. The host picks 256 terms per chunk, or 128 if maxThreadgroupMemoryLength or the occupancy readout favours it. Double precision and forces with more than 4 atoms per term keep the shared kernel.

#### Memory cost

Plan buffer: 4 B per term, 2 B per slot, and about 8 B per local atom per chunk. apoa1pme comes to about 5 MB and stmv an estimated 40 to 50 MB, scaled with the system and allocated once. The existing atomIndices and PARAMS arrays are reused. Threadgroup pad: 12 KB per threadgroup.

#### Correctness risks

Force-group masking must zero the slots of skipped forces. Energy-parameter derivatives stay per thread (GLOBAL_ID indexing now depends on the chunk grid, so the energy buffer must hold at least numChunks*256 entries). The plan assumes static bonded indices. reorderAtoms only swaps identical molecules, which the base's static atomIndices already rely on. Metal's 31-argument limit is why the plan lives in one packed buffer. In MathModeSafe the compiler could contract a term's floats differently in the new kernel, but a bitwise diff of the bonded-only force buffer against base settles that. Halo atoms shared between chunks still take atomics, which is correct, only fewer. Any concurrent-dispatch mode is unaffected, because accumulation stays atomic.

#### Prototype size

About 60 lines of MSL codegen changes and about 180 lines of host plan builder in MetalBondedUtilities, plus the one-word protected change in the common header. About 3 hours to a first measurable build. The kill probe below takes 10 lines and about 45 minutes.

#### Feasible tonight

yes

#### First experiment

Lab-only no-atomics floor: in createForceSource, under a define, replace the 3 ATOMIC_ADDs per atom with sink += force_k, and write sink.x+sink.y+sink.z into energyBuffer at the end so the compiler cannot delete the forces. Run profiler counters mode on apoa1rf, apoa1pme and cellulose, 6df2b8bcb against the probe. Build the chunked kernel only if computeBondedForces falls by 50% or more on apoa1rf and cellulose. If it falls by less than 30%, bonded is gather or latency bound; kill this design and move to SIMD-uniform term ordering. Then check the prototype with a bitwise diff of the long force buffer after one bonded-only evaluation (the bonded force group) against base on apoa1rf, apoa1pme and cellulose, then forces.py and ctest -R TestMetal.

### Design 2: Cluster-owned fused LangevinMiddle step: Part1, velocity constraints, Part2, position constraints and Part3 in one dispatch with the mixed state held in registers

#### Native levers

Apple9 dynamic register allocation: 'On-chip register memory is now dynamically allocated and deallocated over the lifetime of the shader according to what each part of the program actually uses' (tech talk 111375). A branchy kernel therefore does not charge the heavy mixed SETTLE path's register peak to the SIMD groups running SHAKE or free atoms. SIMD-uniform work ordering exploits the 32-wide SIMD groups (WWDC22 10159; lab 004). Apple9's concurrent FP32 and integer issue ('up to 2x ALU performance', tech talk 111375) helps the integer-heavy df64 IEEE conversions that remain. Function constants (MSL 5.8.1) compile hasSettle, hasShake and mixed variants without regenerating source. The design removes 6 serial-encoder barriers per step at about 1.88 us each (lab 008). It needs no grid-wide sync, which MSL does not offer.

#### Mechanism

Add a MetalIntegrateLangevinMiddleStepKernel, registered in MetalKernelFactory in place of the common one when there are no CCMA constraints (true for every benchmark.py test: HBonds with rigid water sends nothing to CCMA, per lab 022). Otherwise it defers to the common kernel. At init, build a unit table ordered [SETTLE waters][SHAKE clusters][free atoms, one per lane], so almost every SIMD group runs one branch. One thread owns one unit, with no cap at 12 threadgroups per core, so cellulose's roughly 136k waters no longer serialize about 3 per thread. The thread loads velm, the three force components, posq, posqCorrection and random[randomIndex+atom] once. It then runs Part1, SETTLE or SHAKE on velocities (the same code as integrationUtilities.cc, turned into device functions on registers), Part2, SETTLE or SHAKE on positions, and Part3, and stores velm, posq and posqCorrection once. posDelta and oldDelta never touch memory. No unit reads another unit's atoms, so the stages need no barrier between them. SETTLE and SHAKE units run concurrently, so the step's constraint cost becomes max(SETTLE chain, SHAKE chain) instead of the sum of four kernels. In mixed precision, the IEEE conversions per atom fall from about 64 to 8. The mixed lane's c1, c3 and c4 (float iteration with a df64 residual) drop into the device functions unchanged and stack. Virtual sites and the CM motion remover stay separate dispatches. An optional extension folds calcCenterOfMassMomentum into Part3 with per-threadgroup partial sums, saving one more dispatch.

#### Expected gain

Single, from the census (subtracting about 5 us overhead per kernel and adding back 1.88 us per serial barrier): today's integration costs about 30 to 35 us per pme step, and the fused kernel is about 10 to 12 us. That saves about 20 us on pme (1.03x), rf and dhfr (1.03 to 1.04x), about 12 to 15 us on gbsa (5 dispatches become 1, 1.04 to 1.05x), and about 20 to 25 us on apoa1 (1.02x). Cellulose and stmv gain under 1%. Mixed base on pme: 276 us census minus about 35 us overhead is about 241 us today. Fused is max(69.9+50.7, 53.5+44.8) minus overhead, about 110 us, plus about 12 us of register-resident Part work, about 120 us in all. That saves about 120 to 150 us of an estimated 863 us mixed pme step (1.16 to 1.21x), and similar on rf and dhfr. On top of mixed c1+c2 the chain is max(51.9+26.5, 35.5+31.9), about 70 us, so the fused kernel still saves about 85 us (about 1.11x). gbsa mixed has no water, so the SHAKE chain stays serial, and the gain comes from Part and barriers, about 40 to 55 us of about 443 (1.10 to 1.14x). apoa1pme mixed saves about 130 us of about 2050 (1.06 to 1.07x), and cellulose mixed about 1.03 to 1.04x.

#### Apple8 (M2) fallback

The same kernel runs on the M2. Without dynamic caching, the M2 allocates the peak register count (the mixed SETTLE path) to every SIMD group, which lowers residency. The kernels are already latency-bound one-thread chains, though, and each wave does in one dispatch what today takes seven, so I expect the M2 to be neutral to positive. The unit order and chunking come from the device's core count. The only fallback trigger is CCMA constraints, vsite-constrained edge cases or a massless constrained atom, and it applies on any chip.

#### Memory cost

Unit table of about 16 B per unit: under 1 MB for apoa1 and about 6 to 8 MB for stmv. The oldDelta allocation (32 B per atom in mixed, 34 MB on stmv) can be skipped on the fused path, a net saving on the M2.

#### Correctness risks

The kernel must reproduce the stage order and semantics exactly: SETTLE and SHAKE on velocities use posq before Part3; velocity.w == 0 atoms are skipped; the random index is base plus atom index; tolerance and the 15-iteration SHAKE cap are unchanged. posDelta is no longer written, so every other reader must be audited (CustomIntegrator and CCMA use it, but those paths keep the common kernel). The fused kernel must also be compiled in as the default, chosen by the constraint topology. Checks: in single precision, compare posq and velm after 100 steps against base with the same seed, bitwise or to a few ulp, on gbsa, rf and pme. The arithmetic per atom is identical, so any larger difference is a bug. For mixed, run drift.py and constraints.py at 1e-8 on both chips, as RULES.md requires.

#### Prototype size

About 400 lines of MSL, mostly moved from integrationUtilities.cc and langevinMiddle.cc into device functions, plus about 150 lines of host code and factory wiring. 8 to 12 hours for the full version. The chain-overlap half alone (the first experiment) is about 90 lines and 2 hours.

#### Feasible tonight

no

#### First experiment

Merged constraint kernel as a cheap proof of the overlap: a Metal-only program that includes the SETTLE and SHAKE bodies with GLOBAL_ID and GLOBAL_SIZE redefined to a local index and stride. Threads below numSettle run SETTLE and the rest run SHAKE, one dispatch for positions and one for velocities. Run the mixed lane's census on pme single and mixed. If the merged position kernel's time sits near max(SETTLE pos, SHAKE pos), about 70 us mixed, instead of the 123 us sum, the overlap is real and the full fusion is worth building. If it sits near the sum, the chains contend for the same ALUs and only the Part and barrier savings remain (about 50 us mixed, 15 us single). Note that the dispatch lane's concurrent encoder, with no barrier between SETTLE and SHAKE, would get the same overlap in about 3 lines. The fused kernel's extra value is removing the Part round trips, the IEEE conversions and 6 barriers.

### Rejected

Native 64-bit atomic add for bonded: it does not exist. MSL 4.1 6.16.4.6 defines only atomic_max and atomic_min on atomic_ulog, relaxed order, and the atomics lane's compile test on the Ultra failed. Device float atomics for bonded: the M2 runs them as a CAS loop (lab 004: 190.8 ms against 0.34 ms on the Ultra), they make results order-dependent, and they need a fold into the fixed-point buffer. The atomics lane already dropped k_float. The chunked gather reaches a lower atomic count and stays deterministic on every family. Threadgroup float atomics: MSL 4.1 only (the review says to keep 4.1 out of tonight's builds), and nondeterministic; the owner gather needs no atomics inside the threadgroup. Skipping the intra-water PME exclusion corrections for rigid waters (64k of apoa1's 218,698 pairs): SETTLE cancels those internal pair forces in the dynamics, but getState forces would change and the forces gate would fail. A persistent megakernel with grid-wide sync for integration plus CM removal: MSL has only threadgroup and SIMD-group barriers, no grid barrier and no forward-progress guarantee across threadgroups. Quad-cooperative SETTLE (one water over 3 to 4 lanes with quad shuffles): shuffle latency is about ALU latency (metal-benchmarks: about 2 cycles of throughput), and SETTLE is mostly sequential, so after the mixed lane's c4 I estimate under 10 us per step. Fast-math or algebraic torsions (removing acos, cos and sin): arithmetic is about 1 to 3 us per step for 240k terms, so it is not the bottleneck until atomics are gone. Revisit only if the chunked kernel's profile shows transcendental cost. Metal 4 encoders, ICBs and indirect dispatch for constraints: benchmark.py has no CCMA host round trips (lab 022), and MTL4 dispatches cost more GPU time than classic serial (lab 008: 2.16 against 1.88 us). df64 stored as raw (hi, lo) pairs: the review measured under 1% gain for a host-wide format change, and the fused kernel removes most conversions without changing the storage format. Sloppy df64 add: Joldes et al. warn against it for mixed signs, and the review limits c2 to div and sqrt. simdgroup_matrix: nothing in bonded or constraint code is a dense 8x8 product.


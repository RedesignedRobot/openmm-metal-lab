# Native Metal design: findBlocksWithInteractions and the rebuild trigger, experiment 028

2026-09-25, research lane (read-only). Base 6df2b8bcb, Metal single, M3 Ultra unless marked. Code is `platforms/metal/src/kernels/findInteractingBlocks.metal` in the base tree (cited as `fib:line`). Tiers: **verified** means I read the code, doc or data file; **reported** means another lane's log says so; **inference** means my model or reasoning. Data and scripts: `experiments/028-ultra-max/research-data/rebuild-rate/` (CPU replay of the trigger) and `research-data/findblocks-emu/` (a numpy emulator of the kernel on real positions).

## Answer

findBlocks has two regimes on this GPU. At dhfr size (737 rows, about 12 SIMD groups per core) it is a latency-bound serial chain, and the longest row sets the time. At apoa1 and up (2882 rows and more) the summed work sets it. So the fixes split in two.

1. Row tail, dhfr size and gbsa only. Turn on the batch that HIP ships (4 SIMD groups per row below 2000 blocks, `HipNonbondedUtilities.cpp:273`; Metal hard-codes 1 with a METAL-TODO, `MetalNonbondedUtilities.cpp:263-264`, both verified). The emulator puts dhfr's longest SIMD group at 38% of today's candidates and 45% of today's modeled work, for 10-13% more tiles. My model predicts 35-55% off each rebuild on rf, pme and amber20-dhfr and nothing on apoa1. Pick the batch by rows per core, not HIP's block count, or the M2 pays the tile cost for nothing.
2. Per-candidate cost, every size. Three changes, each copying a shape CUDA already has or the nblist lane has already built as a knob. (a) Carry each candidate's atom block and center from stage 1 and prefetch its positions (`NB_PREFETCH`). (b) Replace HIP's serial ffs loop with CUDA's unrolled 32-atom mask (new, about 15 lines). (c) Reserve single pairs once per flush, not once per candidate (`NB_PAIRBUF`, CUDA's `saveSinglePairs`). In the model these three take 50-70% off at dhfr size. At apoa1 the gain depends on which bound is real, and the kill tests below tell them apart.
3. Don't merge the wrap commit 0669fddab on its own. In the emulator it moves the longest row onto the few large blocks at the end of the size order. The longest row gets longer on both sizes (pme 117 to 205 candidates, apoa1rf 148 to 263), and the modeled time is flat or worse at batch 1. A hybrid rule (wrap among regular blocks, triangle for the large tail) does work at dhfr size, but batch 4 gets the same tail with a one-line change.
4. Keep the padding at 0.08. The rebuild interval is a staircase: every second step on every explicit test at 0.08, every third from 0.14. The step up costs 15-16% more tiles, pays 1-3% on rf today, and loses everywhere once items 1 and 2 land.
5. Trigger: no change to the criterion. Moving it and gating the chain is the study's design 2 and stays as written. My replay confirms its inputs. Stage the large-block window in sortBoxData (apoa1rf 30.8 us/step, every step) through threadgroup memory. That is worth about 2% on the apoa1 tests.

## Current cost

**Per step (reported, profiler lane, buffers mode, `lanes/profiler.md:122-130`).** findBlocks costs 21.4 us on gbsa (7%, 78 rows), 147.4 on rf (32%), 95.7 on pme (16%), 272.3 on apoa1rf (24%), 174.8 on apoa1pme (10%), 157.3 on apoa1ljpme (7%), 67.4 on amber20-dhfr (12%), 504.4 on cellulose (9%) and 1027.5 on stmv (7%).

- Rebuild fraction: 50.2% on every explicit test, 33.7% on amber20-dhfr and 8.0% on gbsa (profiler `:148` and `:312`, from a gap split of the raw durations). That matches my replay below. The earlier 71-75% apoa1 figures were a classifier artifact.
- Per rebuild, from buffers mode: rf 294 us, pme 191, apoa1rf 542, apoa1pme 348, amber20-dhfr 200, cellulose 1005, stmv 2047.
- Counters mode (`lanes/nblist.md:13-21`) gives rf 305 and apoa1rf 578, which agree with buffers mode within 4-7%. On the PME tests it gives 275 for pme, 687 for apoa1pme and about 2x buffers mode on cellulose and stmv.
- The two modes disagree by up to 2x on every PME test. I calibrate only on the two RF numbers, where they agree. The nblist lane's `NB_TIME` (one command buffer per phase) is the arbiter.

**Rebuild rate against padding (verified, CPU replay of the Metal trigger `fib:189-202`, 400-600 steps per test, `research-data/rebuild-rate/disp-run1.txt`).**

| pad/rc | rf | pme | amber20-dhfr | apoa1rf | apoa1pme | gbsa |
|---|---|---|---|---|---|---|
| 0.06 | 0.517 | 0.650 | 0.485 | 0.512 | 0.600 | 0.150 |
| 0.08 (base) | 0.500 | 0.500 | 0.333 | 0.500 | 0.500 | 0.076 |
| 0.10 (OpenCL) | 0.437 | 0.500 | 0.268 | 0.412 | 0.487 | 0.046 |
| 0.12 | 0.337 | 0.362 | 0.235 | 0.335 | 0.350 | 0.026 |
| 0.14 | 0.320 | 0.333 | 0.198 | 0.300 | 0.333 | 0.016 |
| 0.20 | 0.207 | 0.232 | 0.135 | 0.198 | 0.225 | 0.006 |
| 0.30 | 0.117 | 0.138 | 0.080 | 0.113 | 0.128 | 0.000 |

- The intervals are tight: pme at 0.08 rebuilds every 2 steps on 300 of 300 intervals, and at 0.14 every 3 steps on 200 of 200.
- The largest one-atom displacement over one 4 fs step is 0.0338-0.0351 nm. The trigger fires at pad/2, which is 0.036 nm at rc 0.9, so pme and apoa1pme sit 3-6% above the cliff where the list would rebuild every step.
- A 5 fs variant of these benchmarks would cross that cliff (inference, ballistic scaling).
- Water hydrogens (1.008 amu under rigid water) trigger 97-99% of rebuilds on rf, pme and apoa1. amber20-dhfr repartitions water H too, which is why it rebuilds every third step.

**Kernel work per rebuild (verified, emulator, `research-data/findblocks-emu/`).** The emulator replays the Metal stage 1 tests (`fib:430-449`: sphere plus half-precision box), the atomFlags test (`fib:495`), the atom mask, single pairs at MAX_BITS 4 and per-row tile packing. It runs on lab 009's apoa1 captures and on a 300-step CPU trajectory of the pme system, with the water Hilbert reorder emulated.

- Validation, exact: with MAX_BITS 0 at OpenCL's padding it reproduces lab 009's 55,396 and 43,560 tiles and 1,727,984 and 1,349,142 tile atoms. The emulated size-bin order matches the captured sortedBlocks at 100% of positions.
- Stage 1 candidate counts are not checked against a Metal capture. They come from my reading of `fib:430-449`.

At pad 0.08:

| | rf (dhfr, rc 1.0) | pme (dhfr, rc 0.9) | apoa1rf | apoa1pme |
|---|---|---|---|---|
| rows | 737 | 737 | 2882 | 2882 |
| candidates | 50,647 | 44,969 | 201,534 | 177,711 |
| per row, mean and max (triangle) | 68.7 / 127-135 | 61.0 / 116-117 | 69.9 / 148 | 61.7 / 131 |
| atomFlags popcount k, mean (p10/50/90) | 16.4 (0/15/32) | 15.3 (0/13/32) | 18.8 (1/21/32) | 18.1 (0/19/32) |
| candidates with no pair in range | 38% | 44% | 40% | 44% |
| candidates with single pairs (one returning atomic each) | 57% (28,630) | 53% (23,641) | 52% (104,210) | 51% (89,954) |
| tiles (singles take off) | 9,826 (-30%) | 7,381 (-33%) | 37,641 (-29%) | 28,488 (-32%) |

- The dhfr snapshots from two trajectories differ by under 1% in totals and up to 8% in the row maximum.
- The last dhfr block holds 6 atoms. Its 26 padding lanes load atom 0 (`fib:48`), which gives it a 2.1 nm radius, and the sort puts it last. Loading the block's own first atom instead removes 0.7% of candidates and no tiles.

## Why it is shaped for another GPU

1. **The mask is HIP's serial ffs loop.** HIP's form walks atomFlags with ffs, one threadgroup load and 3 fma per set bit (`fib:526-532`, `__ffs` is `ctz` plus a zero test, `common.metal:19`). CUDA unrolls all 32 atoms and has no loop-carried scan (`cuda/.../findInteractingBlocks.cu:470-476`, verified).
   - Apple GPUs issue in order within a SIMD group. So each ffs iteration waits for its load and fma chain before the next ctz (inference). With k about 15-19 that is roughly 1000 cycles per candidate when there are only 3 SIMD groups per scheduler to hide it, as on dhfr.
   - gbsa is the worst case. At a 2 nm cutoff almost every candidate has k near 32 (inference).
2. **Two dependent global loads per candidate.** The candidate's atom block comes from `sortedBlocks[block2]` (`fib:473`), then `posq` (`fib:483`). Stage 2 also re-reads `sortedBlockCenter[block2]` (`fib:490`), which stage 1 already loaded (`fib:430`).
3. **One returning global atomic per candidate with single pairs** (`fib:554-557`), on one address. That is 104k per apoa1rf rebuild, arriving about once per 5 ns. The M3 Ultra has two dies, so half of them cross UltraFusion to the counter's home (inference; the playbook's open question 4 asks what that costs). CUDA reserves once per flush with a warp prefix sum (`findInteractingBlocks.cu:188-216`, called at `:495` and `:521`).
4. **Batch fixed at 1.** Metal hard-codes one SIMD group per row (`MetalNonbondedUtilities.cpp:263-264`). The upper triangle over size-sorted rows gives the first rows their whole neighbor shell, so on dhfr the longest row has 1.9x the mean candidates. That is a fine shape for 120-CU AMD parts at batch 4. On 60 Apple cores at batch 1, the dhfr kernel lasts as long as its longest row.
5. **sortBoxData rebuilds every large-block box from 31 dependent global loads per thread, every step** (`fib:161-180`, large blocks above 90,000 atoms, `MetalNonbondedUtilities.cpp:70`). This costs apoa1rf 30.8 us/step (reported, profiler `:125`). It is a serial chain of `sortedBlocks[j]` then `blockCenter[index2]`, repeated 31 times.
6. **The trigger runs in the fourth dispatch of every step** (`fib:189-202`). The study covers this (design 2).

## A model to rank the designs (inference)

I cost each SIMD group's work as 150 cycles per 32-block chunk scanned, 900 per candidate (two dependent loads plus ballots), 60 per ffs iteration, and 600 per single-pair atomic, at 1.4 GHz. Kernel time is the larger of two terms:

- the longest SIMD group;
- the summed work over 60 cores x R overlapping SIMD groups.

Two free parameters fit the two trusted points: a 1.45x scale and R of about 15. rf comes out at 300 us per rebuild, tail-bound (207 raw longest group against 90 raw summed). apoa1rf comes out at 560, sum-bound (269 raw longest against 385 raw summed).

A two-parameter fit to two points validates nothing. It ranks the designs and makes falsifiable predictions, and `NB_TIME` checks them. Raw model numbers (us, before the 1.45 scale), tiles, and longest-group candidates at pad 0.08, from `emu2-*.txt`:

| scheme | pme longest cand | pme model | pme tiles | rf model | rf tiles | apoa1rf model | apoa1rf tiles | apoa1pme model | apoa1pme tiles |
|---|---|---|---|---|---|---|---|---|---|
| triangle, batch 1 (base) | 117 | 177 | 7,376 | 207 | 9,832 | 269 | 37,641 | 233 | 28,488 |
| triangle, batch 2 | 70 | 118 | 7,716 | 132 | 10,177 | 190 | 39,085 | 143 | 29,879 |
| triangle, batch 4 | 45 | 79 | 8,302 | 93 | 10,800 | 115 | 41,691 | 101 | 32,472 |
| wrap (0669fddab), batch 1 | 205 | 188 | 7,540 | 211 | 10,017 | 267 | 38,984 | 263 | 29,395 |
| wrap, batch 4 | 59 | 63 | 8,578 | 70 | 11,122 | 114 | 43,214 | 93 | 33,570 |
| hybrid, batch 1 | 94 | 134 | 7,517 | 155 | 9,997 | 268 | 38,324 | 242 | 29,000 |
| hybrid, batch 2 | 56 | 80 | 7,871 | 96 | 10,372 | 188 | 39,743 | 151 | 30,386 |

- Summed work (raw ms): pme 70.1 for triangle and 67.5 for wrap; rf 82.0 and 79.0; apoa1rf 351.3 and 328.9; apoa1pme 305.0 and 284.9. At R=15 the sum term is about 77, 90, 385 and 334 raw us.
- So on apoa1 no ownership or batch change can beat the sum term. Only cheaper candidates can.
- Hybrid means wrap ownership among blocks below the first size bin that holds a block with more than 1.5x the median size (tail: 8 blocks on dhfr, 245 on apoa1rf); pairs involving the tail stay with the smaller block, as in the triangle.

## Design 1: batch by rows per core (dhfr size and gbsa)

**Native levers.** None new. It is more SIMD groups in flight, and the kernel already supports it: `NUM_TILES_IN_BATCH`, and warp w of a row takes every B-th chunk (`fib:337`, `fib:385`). Each SIMD group keeps its own tile buffer in its own threadgroup at `NB_FBTG` 32 (`fib:330`).

**Mechanism.** Set `numTilesInBatch` from rows per core, not from the block count:

- B = 4 when numBlocks < 15 x cores;
- B = 2 below 30 x cores;
- else 1.

On the M3 Ultra that gives B=4 for gbsa (78 blocks) and the dhfr-size tests (737), and 1 for apoa1 and up. On the M2 (10 cores) it gives 1 for everything except gbsa. The thresholds come from R of about 15 (inference) and should be retuned from K1.

**Expected gain (inference, model).** Per rebuild: rf 300 to 135 us, pme 257 to 115, amber20-dhfr similar (-35 to -55% given R uncertainty). Tiles grow 9.8% on rf and 12.6% on pme, because every SIMD group flushes its own partial tile.

Whole step:

- rf: -81 us of findBlocks against +15 us of computeNonbonded (149.6 us x 9.8%), net about -66 us, 13-14%;
- pme: -53 to -76 against +15, net 6-10%;
- amber20-dhfr: about 4% (-37 us against +15);
- gbsa: the 77-candidate first row splits over 3 chunks, so about -60% per rebuild, which at 8% rebuilds is about 10 us of 292 (3%);
- apoa1 and up: none, and HIP agrees (batch 1 at 2000 blocks and up).

**Apple8 (M2) fallback.** The rule above gives B=1 on dhfr and larger (74 rows per core already). The HIP rule would give the M2 the tile cost and no gain.

**Memory cost.** None beyond 10-13% more tiles, which fit today's maxTiles of 20 x numBlocks.

**Correctness risks.** The pair set is unchanged but tiles are grouped differently. Compare (block, atom) pair sets and single-pair sets against batch 1, as lab 009 did, then forces against Reference after 100 MD steps (RULES).

**Prototype size.** 3 lines in `MetalNonbondedUtilities.cpp`, plus `getNumComputeUnits` if it isn't exposed already.

**Feasible tonight.** Yes. `NB_BATCH` exists on the dev tree.

**Kill test (K1).** Zero code: `NB_TIME` per-phase times of findBlocks on rf, pme and apoa1pme at `NB_BATCH` 1, 2, 4, and `NB_WRAP` 0/1 at batch 1. nblist's job2 already queues most of this.

- Predictions: rf and pme batch 4 at -35 to -55% per rebuild, batch 2 at -25 to -36%, wrap at batch 1 within 10% of base on rf and pme, apoa1pme batch 4 within 10%.
- Kill batch 4 for a size class if the per-rebuild saving times 0.5 is less than 1.5x the computeNonbonded growth, or if the ns/day screen regresses on any of rf, pme, dhfr, gbsa.
- If apoa1pme batch 4 gains more than 20%, my tail-versus-sum split is wrong, and the rule should be block count, as HIP does.

## Design 2: a cheap candidate (prefetch, unrolled mask, flush-time singles)

**Native levers.**

- simd_ballot and popcount compaction (Apple6+) and simd_prefix_exclusive_sum (Apple7+), per the study's feature table.
- A uniform threadgroup load broadcast inside a fully unrolled loop, the CUDA shape.
- No MSL 4.1, no cross-threadgroup visibility.

**Mechanism.** Three independent pieces, each behind its own knob so K2 and K3 can split them.

- (a) Candidate pipeline, `NB_PREFETCH` (built). In stage 1, lanes that pass also load `sortedBlocks[block2]`. That load is coalesced across lanes, and they already hold `blockCenterY` (`fib:430`). The lanes write y and the center into threadgroup memory next to `block2Buffer`. Stage 2 then reads both from threadgroup memory, and `posq` for candidate n+1 is issued before the mask of candidate n. The chain goes from two dependent global levels to one overlapped level.
- (b) Unrolled mask, new. In the singlePeriodicCopy path (every benchmark row takes it: dhfr's 0.5 x box minus the largest block half-size is 1.68 nm, above 0.97), replace `fib:526-532` with the 32-step unrolled loop over `posBuffer[j]`, same fma form and same `collectInteractions`. Then add `interacts &= atomFlags`. The mask keeps the result bit-identical to the ffs loop, because the ffs loop only ever tests set bits. A variant switches on the warp-uniform `popcount(atomFlags) > 8`. That keeps the ffs loop for sparse candidates if the unrolled form costs more issue slots on apoa1, where k averages 18.8 and 32 x 5 instructions is about break-even with 18.8 x 11.
- (c) Flush-time singles, `NB_PAIRBUF` (built). This is CUDA's shape: keep each buffered atom's interaction mask, decide single pairs at flush with simd_prefix_exclusive_sum, and reserve with one atomicAdd per flush. Atomics on `interactionCount[1]` fall from 104k to about 7k per apoa1rf rebuild. The 4 ballots and 8 popcounts per candidate at `fib:546-553` move to flush time.

**Expected gain (inference, model).** Candidate cost falls from about 900 to about 400 cycles with (a), the mask from 60 x k to about 200 flat with (b), and the single atomic from 600 to about 50 with (c).

- rf's longest row: 303k to 84k cycles (-72%).
- At dhfr size, all three together: -50 to -70% per rebuild before batching. Stacked on design 1 the kernel becomes sum-bound at about 60-90 us per rebuild on rf.
- gbsa: (b) alone takes about two thirds off each candidate, because k is near 32.
- apoa1: -30 to -50% if the kernel is latency-sum-bound (my R model); -5 to -15% if it is issue-bound. My estimated issue floor is 170-290 us per rebuild, at 200-250 fixed instructions per candidate plus the mask.

**Apple8 (M2) fallback.** Same code. Everything is Apple7 or lower. On the M2's 10 cores the kernel is sum-bound at every size, so expect the apoa1-like result there.

**Memory cost.** Threadgroup memory per SIMD group grows from about 1.8 KB to about 2.3 KB for (a) (33 float4 centers) and about 4 KB for (c) (256 flags). Check occupancy against lab 009's finding that threadgroup size 32-64 is fastest because of the footprint.

**Correctness risks.** (a) and (b) must give bit-identical interactingTiles, interactingAtoms and singlePairs as sets. (c) changes the order of singlePairs, not the set. The overflow check `pairIndex+count <= maxSinglePairs` has to move to flush time with the same resize path. Then forces against Reference after 100 steps.

**Prototype size.** (a) and (c) exist as knobs. (b) is about 15 lines.

**Feasible tonight.** Yes for K2. (b) needs one dev commit.

**Kill tests.**

- **K2:** `NB_TIME` on rf, pme, gbsa and apoa1pme with `NB_PREFETCH` 0/1 and `NB_PAIRBUF` 0/1, at batch 1.
  - Predictions: prefetch -15 to -30% on rf and pme (the model's longest row: -21%), pair buffer -5 to -15%.
  - If prefetch gains under 10% on apoa1pme while gaining over 15% on pme, apoa1 is issue-bound. Then apoa1's lever is instruction count, which means (b) with the popcount switch plus (c).
  - Kill (c) if it gains under 5% on apoa1pme, where the one-address atomic is busiest.
- **K3:** unrolled mask at thresholds 0 (always), 8 and 33 (never), on the same tests, with the tile sets compared.
  - Predictions: gbsa -40% or more, rf and pme -20 to -40% (model: -37% on the longest row), apoa1pme within 5%.
  - Kill if rf and pme gain under 10%.

## Design 3: hybrid ownership, if the tile cost of batch 4 matters

**Mechanism.** Rows below K scan a wrap window of K/2 blocks inside [0, K), then the whole tail [K, NB). Rows at K and above scan the triangle.

- K is the first sorted index of the first size bin whose sum of half-sizes exceeds an absolute threshold. About 1.8 nm works for water blocks, whose median is 1.2. sortBoxData finds K where the bin steps over the threshold.
- The emulator's pair counts match the triangle exactly for every scheme ("owned" column in `emu2-*.txt`).

**Expected gain (inference).** At dhfr size, batch 2 with hybrid gets batch 4's tail (pme 80 raw against 79; rf 96 against 93) with 6.7% more tiles instead of 12.6% on pme, and 5.5% instead of 9.8% on rf. That is about 7 us/step on pme (1.2%) over design 1. On apoa1 it gains nothing at batch 1.

**Prototype size.** About 30 lines in `fib` plus K in sortBoxData.

**Feasible tonight.** No, and it isn't worth doing before K1 shows the tile cost of batch 4.

**Kill test.** Only if K1 passes. Pass if it matches batch 4's per-rebuild time within 10% at 5% or more fewer tiles.

## Design 4: stage the large-block window in sortBoxData (apoa1 and up)

**Mechanism.**

1. Each threadgroup of T threads loads `sortedBlocks`, then the centers and boxes, for [base, base+T+31) into threadgroup memory, two coalesced levels.
2. Each thread runs today's 31-step loop (`fib:167-177`) from threadgroup memory, in the same order and with the same running-center wrap.
3. The large-block boxes stay bit-identical, and so does everything downstream.

**Expected gain (inference).** Today the first 2882 of its numAtoms threads (`MetalNonbondedUtilities.cpp:420`), 90 SIMD groups, each walk a 31-deep chain of two dependent global loads, about 22 us, which matches the 30.8 measured. Staged, it is one load level plus about 600 ALU instructions per thread: 30.8 to under 8 us/step. That is about 2% on apoa1rf, 1.3% on apoa1pme and 1% on apoa1ljpme, less on cellulose and stmv. It stacks with the study's design 2, which runs sortBoxData only on rebuild steps.

**Apple8 (M2) fallback.** Same code.

**Memory cost.** (T+31) x 36 B of threadgroup memory (float4 center, float4 box, index).

**Correctness risks.** Low. Compare largeBlockCenter and largeBlockBoundingBox bitwise against base.

**Prototype size.** About 25 lines.

**Feasible tonight.** Yes.

**Kill test (K4).** `NB_TIME` sortBoxData on apoa1rf: pass under 12 us/step with identical large boxes.

## The trigger and the padding

**Criterion: keep it.** It is exact. It is the smallest padding that holds T=2 at both cutoffs: 0.07 at rc 1.0 has zero margin against D(1)max. The study already rejected the only exact loosening I know (top-2 displacements, 2-3% longer life).

**Where it runs.** Move it into findBlockBounds and gate the chain with it (study design 2, unchanged). It saves the block sort on non-rebuild steps and is the control plane the dual list needs.

**Padding decision rule (inference, emulator plus replay).** Going from 0.08 to 0.14 (T=2 to T=3 on the explicit tests):

- Costs: +15.3-15.9% tiles, +8.3-8.9% single pairs, and +8.5-10% per-rebuild work.
- Per step: findBlocks falls by about C x (0.5 - 1.095 x r_0.14) and computeNonbonded grows by about 0.155 x N.
- It pays when C > about 1.15 N.

At today's costs:

- rf: -44 + 23 = -21 us/step (4%);
- pme: -26 + 19 = -7 (1%);
- apoa1rf: -94 + 74 = -20 (2%);
- apoa1pme: -48 + 64 = +16 (loss);
- amber20-dhfr at 0.14: -24 + 19 = -5.

After designs 1 and 2 halve C or better, every test loses. **Kill test (K5):** run it last, after K1-K3 land. Screen `NB_PAD=140` against 80 on rf, pme, apoa1rf, apoa1pme and dhfr, and ship only if ns/day improves on all five. I expect it to fail.

**Numbers for the study's dual list (design 1 there).**

- At p_out = 0.2 nm (f = 0.222 at rc 0.9) the outer rebuild fraction is 0.200-0.207 on pme and apoa1pme, a 2.4-2.5x interval against the study's assumed 2.8x. Its savings shrink by about 12%.
- The outer build at MAX_BITS 0 and pad 0.20-0.25 x rc (p_out 0.18-0.225 nm) has 13-19% more candidates and 29-42% more tile atoms than today's list at MAX_BITS 0 and 0.08 (dhfr, rc 0.9). That puts k at about 1.15-1.4, inside the study's range.

## Rejected

1. **Wrap ownership (0669fddab) as the tail fix at batch 1.** Emulator: the longest row grows on both sizes. On apoa1pme it grows from 131 to 279 candidates, because the large blocks sorted last now own half their big neighbor shells. p99 improves on dhfr (109 to 91), but the kernel waits for the max. Batch 4 fixes the tail. Keep 0669fddab only if K1 shows it gaining on its own.
2. **Loading the block's own first atom into padding lanes** (`fib:48`): 0.7% fewer candidates on dhfr, 0 tiles.
3. **Padding below 0.08:** T=1 cliff, 3-6% margin at rc 0.9.
4. **Padding 0.14 now:** see the decision rule. It loses on apoa1pme today and on everything after designs 1 and 2.
5. **Lookahead rebuild overlapped with the current step.**
   - Keeping T=2 needs the list to cover a 2-step lag: pad above 2 x D(2)max = 0.136 nm at rc 0.9, +16-21% tiles.
   - It needs the concurrent encoder, which the lead stopped at 21:30Z (`lanes/dispatch.md:31`).
   - It is worth about 8 us/step once the knobs land.
6. **Overlapping the rebuild chain with PME and bonded kernels** (GROMACS runs pruning "in a rolling fashion ... between force computations", Pall et al. 2020, V.E): the same concurrency blocker. Revisit if the dispatch lane revives concurrent dispatch. findBlocks shares no written buffer with the PME or bonded kernels, so it is the cleanest candidate for a second chain.
7. **GROMACS's fixed list lifetime with a drift-tolerance buffer** (Pall et al. 2020, V.B and V.D): it trades OpenMM's exact list for a tolerance. That is a physics contract change, out of scope.
8. **A tighter stage 1 to cut the 38-44% empty candidates:** stage 2's per-atom sphere test (`fib:495`) is already the cheapest exact filter. Design 2 makes an empty candidate cheap instead.
9. **Broadcasting x positions from registers with simd_shuffle instead of `posBuffer`:** 4 shuffles per atom against one uniform threadgroup float4 load (inference). Cheap to add to K3 if anyone doubts it.
10. **Per-row partial rebuild:** each row would need its own reference time and a displacement bound over every candidate's atoms. At T=2 the Maxwell tail touches every row anyway. GROMACS drops displacement triggers for the same reason: "the likelihood of requesting a pair list update at a step approaches unity as the size of the system increases" (Pall et al. 2020, V.D).
11. **Half-precision positions in the mask:** tiles would stop being bit-identical to base and the boundary gets a rounding margin. It isn't worth it once the mask is unrolled.
12. **Cell grid, simdgroup_matrix masks, ray tracing, top-2 trigger, Metal 4:** rejected in the study's neighbor-list area, and nothing here changes that.

## Order of work (for the nblist lane, which owns the code)

K1 and K2 run on knobs that exist, and job2 already covers most of K1. Then comes K3 (one dev commit) and K4 (one small commit). Ship design 1 with the rows-per-core rule, (a) and (c) if K2 passes, and (b) if K3 passes. Design 3 and K5 come last, and only if their preconditions hold.

## Sources

- Code (verified): `platforms/metal/src/kernels/findInteractingBlocks.metal:21` (half BoundingBox), `:48`, `:161-202`, `:306`, `:337`, `:385`, `:430-449`, `:473-495`, `:526-557`, `:572-599`. `MetalNonbondedUtilities.cpp:70`, `:263-264`, `:417-420`. `MetalContext.cpp:176` (AMD_RDNA, so 32-wide), `:594-611`. `common.metal:19`. `platforms/hip/src/HipNonbondedUtilities.cpp:273`. `platforms/cuda/src/kernels/findInteractingBlocks.cu:188-216`, `:456-476`, `:495`, `:521`.
- Lab data (verified): `experiments/009-neighbour-list/README.md` (captures, validation counts, threadgroup memory finding). `research-data/rebuild-rate/disp-run1.txt`. `research-data/findblocks-emu/emu-cap.txt`, `emu-dhfr.txt`, `emu2-cap.txt`, `emu2-dhfr.txt`.
- Lane logs (reported): `lanes/profiler.md:122-130`, `:148`, `:291`, `:312`. `lanes/nblist.md:13-21`, `:55`. `lanes/dispatch.md:31`.
- Pall, Zhmurov, Bauer, Abraham, Lundborg, Gray, Hess, Lindahl, "Heterogeneous parallelization and acceleration of molecular dynamics simulations in GROMACS", J. Chem. Phys. 153, 134110 (2020), arXiv:2006.09167, sections V.B, V.D, V.E, V.F (verified in the PDF).

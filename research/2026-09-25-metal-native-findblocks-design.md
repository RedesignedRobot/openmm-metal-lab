# Native Metal design: findBlocksWithInteractions and the rebuild trigger, experiment 028

2026-09-25, research lane (read-only). Revised at 23:45Z against nblist's `NB_TIME` knob scan (`lanes/nblist.md` 23:12Z, dev tree 163f2838e): the model's R, design 2's (a) and (c), design 3, wrap at batch 1 and the padding rule changed. Base 6df2b8bcb, Metal single, M3 Ultra unless marked. Code is `platforms/metal/src/kernels/findInteractingBlocks.metal` in the base tree (cited as `fib:line`). Tiers: **verified** means I read the code, doc or data file; **reported** means another lane's log says so; **inference** means my model or reasoning. Data and scripts: `experiments/028-ultra-max/research-data/rebuild-rate/` (CPU replay of the trigger) and `research-data/findblocks-emu/` (a numpy emulator of the kernel on real positions).

## Answer

findBlocks has two regimes on this GPU. At batch 1 on dhfr size (737 rows, about 12 SIMD groups per core) it is a latency-bound serial chain, and the longest row sets the time. Everywhere else, apoa1 and up at batch 1 and dhfr size at batch 4, the summed work sets it, spread over about 11-12 SIMD groups per core. So batch 4 fixes the tail once, and after that only less work helps.

1. Row tail, dhfr size and gbsa only. Turn on the batch that HIP ships (4 SIMD groups per row below 2000 blocks, `HipNonbondedUtilities.cpp:273`; Metal hard-codes 1 with a METAL-TODO, `MetalNonbondedUtilities.cpp:263-264`, both verified). The emulator puts dhfr's longest SIMD group at 38% of today's candidates and 45% of today's modeled work, for 10-13% more tiles. Measured on pme (`NB_TIME`): 43% off each rebuild (280.7 to 160.6 us) for 2.7% more computeNonbonded time. Pick the batch by rows per core, not HIP's block count, or the M2 pays the tile cost for nothing; nonbonded's 6d72c3ae9 (batch 4 below 32 x cores blocks) does that.
2. Less work per rebuild, every size. This is the only lever left once batch 4 lands. Of the three per-candidate changes, two are measured dead: (a) prefetching each candidate's positions (`NB_PREFETCH`) is 2-3% slower everywhere, and (c) reserving single pairs once per flush (`NB_PAIRBUF`) gains 7% on pme but loses 6% on apoa1pme. (b), CUDA's unrolled 32-atom mask in place of HIP's serial ffs loop, is queued as `NB_UNROLL` (job3). The measured work cut is MAX_BITS 0, which takes 18% off each rebuild on pme and 12% on apoa1pme and changes computeNonbonded too (see "computeNonbonded cost of list shape").
3. Don't merge the wrap commit 0669fddab. Measured, it is 13% faster than the triangle on pme at batch 1 (the model said flat or worse) and 34% slower on apoa1pme, where it moves the longest row onto the large blocks at the end of the size order (131 to 279 candidates). At batch 4 it gains nothing on pme (164.1 against 160.6 us) and costs 4% computeNonbonded. The hybrid rule (design 3) is dead for the same reason: at batch 4 the kernel is sum-bound, and ownership only reshapes the longest group.
4. Padding is open again, and my first rule was wrong. The rebuild interval is a staircase: every second step on every explicit test at 0.08, every third from 0.12-0.14. More padding adds tiles, but on PME it makes computeNonbonded cheaper, because it moves in-range pairs out of the single-pair path. At batch 4 the model gives pme about -23 us per step at 0.12 and -32 at 0.16, mostly from the rebuild rate. The batch 4 whole-step screen and md100 decide.
5. Trigger: no change to the criterion. Moving it and gating the chain is the study's design 2 and stays as written. My replay confirms its inputs. Stage the large-block window in sortBoxData (apoa1rf 30.8 us/step, every step) through threadgroup memory. That is worth about 2% on the apoa1 tests.

## Current cost

**Per step (reported, profiler lane, buffers mode, `lanes/profiler.md:122-130`).** findBlocks costs 21.4 us on gbsa (7%, 78 rows), 147.4 on rf (32%), 95.7 on pme (16%), 272.3 on apoa1rf (24%), 174.8 on apoa1pme (10%), 157.3 on apoa1ljpme (7%), 67.4 on amber20-dhfr (12%), 504.4 on cellulose (9%) and 1027.5 on stmv (7%).

- Rebuild fraction: 50.2% on every explicit test, 33.7% on amber20-dhfr and 8.0% on gbsa (profiler `:148` and `:312`, from a gap split of the raw durations). That matches my replay below. The earlier 71-75% apoa1 figures were a classifier artifact.
- Per rebuild, from buffers mode: rf 294 us, pme 191, apoa1rf 542, apoa1pme 348, amber20-dhfr 200, cellulose 1005, stmv 2047.
- Counters mode (`lanes/nblist.md:13-21`) gives rf 305 and apoa1rf 578, which agree with buffers mode within 4-7%. On the PME tests it gives 275 for pme, 687 for apoa1pme and about 2x buffers mode on cellulose and stmv.
- The two modes disagree by up to 2x on every PME test. I calibrate only on the two RF numbers, where they agree. The nblist lane's `NB_TIME` (one command buffer per phase) is the arbiter.
- `NB_TIME` (`lanes/nblist.md` 23:12Z, median of rebuild steps) gives pme 280.7 us (candidate sort paths) and 268.5 (base sort paths), apoa1pme 619.9 and 544.9, apoa1ljpme 788.6 and 571.2. `NB_TIME` commits each phase without a host wait (163f2838e `MetalNonbondedUtilities.cpp:50-75`), so a phase shares the GPU with any command buffer it doesn't depend on. On apoa1 the PME atom sort runs on every rebuild step, so the apoa1 numbers are upper bounds. On pme it runs every second step, and rebuilds with and without it differ by -8% to +10% with no consistent sign, so the pme numbers stand (`research-data/findblocks-emu/lsort.py`).

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

My first fit used the two RF points from the census: a 1.45x scale and R of about 15. `NB_TIME` on pme refits both. Batch 1 gives a 1.59x scale (280.7 us against 177 raw), and batch 4 gives R of about 11.6 (160.6 us against 70.1 raw ms summed, 60 cores). With those numbers every pme point lands where the two terms say, if the terms add near the crossover instead of taking the max:

- batch 4 and wrap at batch 4 sit on the sum term: 160.6 and 164.1 measured, against 125 and 100 from the longest group scaled;
- batch 2 and wrap at batch 2 sit 14-17% above both terms (214.2 and 180.1 measured, longest group 188 and 154, sum 160 and 154);
- wrap at batch 1 measured 245.5, below the 299 the longest group predicts. The per-candidate weight is too high, which the prefetch result also says: hiding the two dependent loads bought nothing.

What caps R at about 12 is open: threadgroup slots or memory per core (about 1.8 KB per 32-thread group here), or issue. `NB_FBTG` 64 and 128 at batch 4 tell a threadgroup cap apart; `NB_TIME_WAIT` removes the overlap. Not the single-pair counter (apoa1pme at batch 1 already takes one candidate atomic per 7 ns, and the pair buffer made it slower) and not bandwidth (about 35 MB per dhfr rebuild from L2-resident arrays, about 220 GB/s).

Raw model numbers (us, before the scale), tiles, and longest-group candidates at pad 0.08, from `emu2-*.txt`, with the pme `NB_TIME` per rebuild:

| scheme | pme longest cand | pme model | pme measured | pme tiles | rf model | rf tiles | apoa1rf model | apoa1rf tiles | apoa1pme model | apoa1pme tiles |
|---|---|---|---|---|---|---|---|---|---|---|
| triangle, batch 1 (base) | 117 | 177 | 280.7 | 7,376 | 207 | 9,832 | 269 | 37,641 | 233 | 28,488 |
| triangle, batch 2 | 70 | 118 | 214.2 | 7,716 | 132 | 10,177 | 190 | 39,085 | 143 | 29,879 |
| triangle, batch 4 | 45 | 79 | 160.6 | 8,302 | 93 | 10,800 | 115 | 41,691 | 101 | 32,472 |
| wrap (0669fddab), batch 1 | 205 | 188 | 245.5 | 7,540 | 211 | 10,017 | 267 | 38,984 | 263 | 29,395 |
| wrap, batch 2 | | 97 | 180.1 | 7,913 | | | | | | |
| wrap, batch 4 | 59 | 63 | 164.1 | 8,578 | 70 | 11,122 | 114 | 43,214 | 93 | 33,570 |
| hybrid, batch 1 | 94 | 134 | | 7,517 | 155 | 9,997 | 268 | 38,324 | 242 | 29,000 |
| hybrid, batch 2 | 56 | 80 | | 7,871 | 96 | 10,372 | 188 | 39,743 | 151 | 30,386 |

- Summed work (raw ms): pme 70.1 for triangle and 67.5 for wrap; rf 82.0 and 79.0; apoa1rf 351.3 and 328.9; apoa1pme 305.0 and 284.9. At R=11.6 the sum term is about 101, 118, 505 and 438 raw us.
- So on apoa1, and at dhfr size once batch 4 lands, no ownership or batch change can beat the sum term. Only less work can.

## computeNonbonded cost of list shape (measured against emulated counts)

The list findBlocks writes sets computeNonbonded's work, so every findBlocks knob has a nonbonded price. `emu3.py` replays the list on the same positions and counts, per config: tiles, filled slots, active j-steps (steps where any lane has r < rc, so the SIMD group runs the interaction body, `nonbonded.metal:322-344` at 163f2838e), single pairs, and single pairs inside the real cutoff (only those run the body and the six 64-bit atomicAdds, `:451-495`; each 64-bit add is one or two 32-bit atomics, `common.metal:57-67`). Verified counts, `research-data/findblocks-emu/emu3-out.txt`:

| dhfr (pme test), rc 0.9 | tiles | active steps per tile | single pairs | in range |
|---|---|---|---|---|
| pad 0.08, MAX_BITS 4, batch 1 | 7,354 | 31.4 | 262,291 | 104,306 (40%) |
| batch 4 | 8,279 | 30.0 | same | same |
| MAX_BITS 0 | 10,937 | 30.4 | 0 | 0 |
| pad 0.12 | 8,115 | 31.3 | 278,665 | 67,005 (24%) |
| pad 0.16 | 8,910 | 31.2 | 294,072 | 41,195 (14%) |

apoa1 (rc 0.9) moves the same way: tiles 28,488 / 41,766 at MAX_BITS 0 / 31,370 and 34,433 at pad 0.12 and 0.16; in-range singles 376k / 0 / 237k / 146k.

- Tiles have no cheap steps. Even the tiles MAX_BITS 0 adds run 28 of 32 steps, though 209k of the slots it adds on apoa1 have no in-range pair. So a tile costs about 32 full bodies whatever it holds.
- `nonbonded` does not depend on list age: flat within 1% at ages 0 to 4 steps (`age.py`). The padding effect is list shape.
- A linear model per test (tiles, filled slots, in-range singles, all singles) fits the 9 measured configs within noise (rms 0.5, 0.8 and 1.6 us on pme, apoa1pme and apoa1ljpme; `fit.py`). Batch 4 adds only empty slots, so it prices a tile cleanly: 3.6 ns on pme, 1.5 on apoa1pme, 6.9 on apoa1ljpme (GPU time, us per 1000 tiles).
- After the tile term, the rest of each config's change differs between apoa1ljpme and apoa1pme by 0.22-0.27 ns per in-range single removed, steady across padding 0.12, 0.16 and MAX_BITS 0. The fitted in-range single costs 0.25-0.29 ns on PME and 0.045 on LJPME.

Mechanism (inference). PME's body is cheap, so computeNonbonded is bound by the atomic and memory path. An in-range single pair costs six emulated 64-bit atomics and two gathers for one interaction; the same pair inside a tile shares its slot's atomics with the slot's other pairs. Break-even is about 0.6 in-range pairs per atom2, so nearly every single is cheaper in a tile, and more padding or MAX_BITS 0 speed the kernel up. LJPME's body is heavier (a tile costs 4.6x as much on apoa1ljpme as on apoa1pme), so the kernel is ALU-bound: single-pair atomics hide under other SIMD groups' ALU work, and every added tile costs 32 full steps. Break-even there is about 4 pairs, which is why MAX_BITS 4 wins on LJPME and more padding costs it. Register pressure would push the other way, making LJPME singles dearer. Zero-code check: ALU against memory limiter counters on computeNonbonded for apoa1pme and apoa1ljpme.

Rule this gives: MAX_BITS 0 for cheap bodies (Coulomb with PME, RF or plain cutoff, plus LJ), 4 for heavy ones (LJPME; CustomNonbondedForce and softcore untested). The choice is per NonbondedUtilities, because every nonbonded force compiles into one kernel. The model predicts MAX_BITS 1 or 2 beats 0 by 2-4% on PME (pme 103.0-104.2 us against 106.4; apoa1pme 352-353 against 367.5), because out-of-range singles cost less than a slot; screen-mb tests that. The mb0 point is the model's only anchor without singles, and leave-one-out misses it, so treat those as predictions.
- Hybrid means wrap ownership among blocks below the first size bin that holds a block with more than 1.5x the median size (tail: 8 blocks on dhfr, 245 on apoa1rf); pairs involving the tail stay with the smaller block, as in the triangle.

## Design 1: batch by rows per core (dhfr size and gbsa)

**Native levers.** None new. It is more SIMD groups in flight, and the kernel already supports it: `NUM_TILES_IN_BATCH`, and warp w of a row takes every B-th chunk (`fib:337`, `fib:385`). Each SIMD group keeps its own tile buffer in its own threadgroup at `NB_FBTG` 32 (`fib:330`).

**Mechanism.** Set `numTilesInBatch` from rows per core, not from the block count. Batching pays while the longest row outlasts the sum term, which with the longest row at about 2x the mean holds below about 2 x R x cores blocks (about 1,400 on the M3 Ultra). nonbonded's 6d72c3ae9 uses B = 4 below 32 x cores (1,920 on the Ultra, 320 on the M2), which splits every benchmark test the same way: B=4 for gbsa (78 blocks) and the dhfr-size tests (737), 1 for apoa1 and up, and 1 on the M2 for everything except gbsa. At dhfr size batch 4 already reaches the sum term, so batch 8 buys nothing.

**Measured gain (`NB_TIME`, pme).** Per rebuild 280.7 to 214.2 us at batch 2 (-24%) and 160.6 at batch 4 (-43%); the early exit rises from 5.9 to 9.5 us, because 4x the threadgroups launch with their full threadgroup memory. computeNonbonded rises 2.7% (124.4 to 127.8 us), not the 12.6% the tile count suggested: batch 4's extra tiles are mostly empty slots, which skip the atom2 atomics. apoa1pme at batch 4 gains 7% against the base sort paths or 18% against the candidate's (the gap between those two rows is unexplained process state, nblist 23:12Z) and costs 1.4% nonbonded; apoa1ljpme costs 6%.

Whole step at batch 4 (my arithmetic from the model before the scan; the screen supersedes it):

- rf: -81 us of findBlocks against +15 us of computeNonbonded (149.6 us x 9.8%), net about -66 us, 13-14%;
- pme: measured parts give -58 us of findBlocks per step (rebuild -60, early exit +1.8) and +3.4 us of computeNonbonded, about 9% of a 600 us step;
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
- Result on pme (23:12Z): batch 4 -43% (inside), batch 2 -24% (just outside), wrap at batch 1 -13% (outside; the model's per-candidate weight is too high). apoa1pme batch 4: -7% or -18% depending on the reference row. rf is not in the scan.
- Kill batch 4 for a size class if the per-rebuild saving times 0.5 is less than 1.5x the computeNonbonded growth, or if the ns/day screen regresses on any of rf, pme, dhfr, gbsa. pme passes the first test (60 us against 3.4).
- If apoa1pme batch 4 gains more than 20%, my tail-versus-sum split is wrong, and the rule should be block count, as HIP does. It didn't cross 20%, but the model predicts no gain there, so even 7% is a partial miss, and the apoa1 numbers are upper bounds. The isolated `NB_TIME_WAIT` run decides.

## Design 2: a cheap candidate (prefetch, unrolled mask, flush-time singles)

**Native levers.**

- simd_ballot and popcount compaction (Apple6+) and simd_prefix_exclusive_sum (Apple7+), per the study's feature table.
- A uniform threadgroup load broadcast inside a fully unrolled loop, the CUDA shape.
- No MSL 4.1, no cross-threadgroup visibility.

**Mechanism.** Three independent pieces, each behind its own knob so K2 and K3 can split them.

- (a) Candidate pipeline, `NB_PREFETCH` (built). In stage 1, lanes that pass also load `sortedBlocks[block2]`. That load is coalesced across lanes, and they already hold `blockCenterY` (`fib:430`). The lanes write y and the center into threadgroup memory next to `block2Buffer`. Stage 2 then reads both from threadgroup memory, and `posq` for candidate n+1 is issued before the mask of candidate n. The chain goes from two dependent global levels to one overlapped level.
- (b) Unrolled mask, new. In the singlePeriodicCopy path (every benchmark row takes it: dhfr's 0.5 x box minus the largest block half-size is 1.68 nm, above 0.97), replace `fib:526-532` with the 32-step unrolled loop over `posBuffer[j]`, same fma form and same `collectInteractions`. Then add `interacts &= atomFlags`. The mask keeps the result bit-identical to the ffs loop, because the ffs loop only ever tests set bits. A variant switches on the warp-uniform `popcount(atomFlags) > 8`. That keeps the ffs loop for sparse candidates if the unrolled form costs more issue slots on apoa1, where k averages 18.8 and 32 x 5 instructions is about break-even with 18.8 x 11.
- (c) Flush-time singles, `NB_PAIRBUF` (built). This is CUDA's shape: keep each buffered atom's interaction mask, decide single pairs at flush with simd_prefix_exclusive_sum, and reserve with one atomicAdd per flush. Atomics on `interactionCount[1]` fall from 104k to about 7k per apoa1rf rebuild. The 4 ballots and 8 popcounts per candidate at `fib:546-553` move to flush time.

**Measured (`NB_TIME`, batch 1).** (a) prefetch: pme +2.4%, apoa1pme +2.1%, apoa1ljpme +2.0% per rebuild, against a predicted -15 to -30%. (c) pair buffer 128: pme -7.4%, apoa1pme +6.5%, apoa1ljpme -4.3%. Both are dead. The model's 900 cycles per candidate, mostly two dependent load levels, was wrong: other SIMD groups already hide those loads. The mask (b) is the piece left, and gbsa, where k is near 32, is where it should show first. The prediction below for (b) stands until K3 runs.

- (b) takes the mask from 60 x k cycles to about 200 flat (inference). gbsa: about two thirds off each candidate.
- apoa1: the kernel is sum-bound, so (b) gains in proportion to the mask's share of total work, which the emulator can't price after the (a) miss.

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
  - Result (job2, 23:12Z): prefetch lost 2-3% everywhere and the pair buffer lost 6% on apoa1pme. Both killed.
- **K3:** unrolled mask at thresholds 0 (always), 8 and 33 (never), on the same tests, with the tile sets compared.
  - Predictions: gbsa -40% or more, rf and pme -20 to -40% (model: -37% on the longest row), apoa1pme within 5%.
  - Kill if rf and pme gain under 10%.

## Design 3: hybrid ownership (dead)

Killed by the 23:12Z scan. At batch 4 dhfr size sits on the sum term, and wrap at batch 4 measured 164.1 us against the triangle's 160.6. Hybrid at batch 2 would sit near wrap at batch 2 (180.1 measured), above batch 4, to save about 430 tiles (about 1.5 us of computeNonbonded at 3.6 ns per tile). The original design follows for the record.

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

**Padding decision rule (emulator plus replay plus `NB_TIME`).** My first rule priced the extra tiles as computeNonbonded growth (+15.5% tiles as +15.5% N) and said every test loses once C halves. The scan refutes the premise. Measured at batch 1 (`NB_TIME`, pad 0.08 / 0.12 / 0.16):

- rebuild rate 0.50 / 0.36 / 0.30 on pme, 0.50 / 0.36 / 0.29 on apoa1pme, 0.50 / 0.35 / 0.29 on apoa1ljpme;
- findBlocks per rebuild +3 to 5% and +7 to 9%;
- computeNonbonded: pme 124.4 / 120.1 / 117.4 us, apoa1pme 423.1 / 397.2 / 388.5, apoa1ljpme 446.6 / 473.3 / 507.4.

Tiles do grow (+10% and +21%), but in-range single pairs fall 36% and 61%, and on PME a single costs more than the slot that replaces it (see "computeNonbonded cost of list shape"). So per step: findBlocks falls by C x (0.5 - r x w), with w the per-rebuild growth, and computeNonbonded moves by the list-shape model's delta, negative on PME at MAX_BITS 4 and positive on LJPME.

At batch 4 on pme (model, findBlocks per rebuild scaled from batch 1 to about 168 and 177 us): computeNonbonded 127.8 measured, 122.9 at 0.12, 121.3 at 0.16, for about -23 and -32 us per step against batch 4 at 0.08, most of it from the rebuild rate. At MAX_BITS 0 the nonbonded side turns into a cost (109.9 / 114.8 / 120.2 predicted), because every extra pair goes into tiles, and the net shrinks to about -10 us.

**Kill test (K5):** whole-step screen at batch 4 of `NB_PAD` 120 and 160 against 80 on rf, pme and dhfr, then with MAX_BITS 0, plus md100 and an M2 memory look. Ship a padding only where ns/day improves; I now expect pme-size PME tests to pass at MAX_BITS 4 and apoa1ljpme to lose on computeNonbonded.

**Numbers for the study's dual list (design 1 there).**

- At p_out = 0.2 nm (f = 0.222 at rc 0.9) the outer rebuild fraction is 0.200-0.207 on pme and apoa1pme, a 2.4-2.5x interval against the study's assumed 2.8x. Its savings shrink by about 12%.
- The outer build at MAX_BITS 0 and pad 0.20-0.25 x rc (p_out 0.18-0.225 nm) has 13-19% more candidates and 29-42% more tile atoms than today's list at MAX_BITS 0 and 0.08 (dhfr, rc 0.9). That puts k at about 1.15-1.4, inside the study's range.

## Rejected

1. **Wrap ownership (0669fddab).** On apoa1pme the longest row grows from 131 to 279 candidates, because the large blocks sorted last now own half their big neighbor shells; measured 34% slower per rebuild. On pme it is 13% faster at batch 1, but batch 4 is faster still, and wrap on top of batch 4 adds nothing (164.1 against 160.6 us) while costing 4% computeNonbonded.
2. **Loading the block's own first atom into padding lanes** (`fib:48`): 0.7% fewer candidates on dhfr, 0 tiles.
3. **Padding below 0.08:** T=1 cliff, 3-6% margin at rc 0.9.
4. **Padding above 0.08 on LJPME:** computeNonbonded rises 6% at 0.12 and 14% at 0.16 on apoa1ljpme, because its extra tiles cost full ALU steps and its singles are cheap. The rebuild saving may still cover it; the whole-step screen decides.
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

K1 and K2 ran in job2 (23:12Z): design 1 passes on pme, (a) and (c) are dead, design 3 is dead. K3 (`NB_UNROLL`) and K4 (`NB_STAGEBOX`) are queued in job3, with `NB_TIME_WAIT` isolating each phase. Ship design 1 with the rows-per-core rule (6d72c3ae9), (b) if K3 passes, MAX_BITS by body cost after screen-mb, and a padding only after K5.

## Sources

- Code (verified): `platforms/metal/src/kernels/findInteractingBlocks.metal:21` (half BoundingBox), `:48`, `:161-202`, `:306`, `:337`, `:385`, `:430-449`, `:473-495`, `:526-557`, `:572-599`. `MetalNonbondedUtilities.cpp:70`, `:263-264`, `:417-420`. `MetalContext.cpp:176` (AMD_RDNA, so 32-wide), `:594-611`. `common.metal:19`. `platforms/hip/src/HipNonbondedUtilities.cpp:273`. `platforms/cuda/src/kernels/findInteractingBlocks.cu:188-216`, `:456-476`, `:495`, `:521`.
- Lab data (verified): `experiments/009-neighbour-list/README.md` (captures, validation counts, threadgroup memory finding). `research-data/rebuild-rate/disp-run1.txt`. `research-data/findblocks-emu/emu-cap.txt`, `emu-dhfr.txt`, `emu2-cap.txt`, `emu2-dhfr.txt`.
- Lane logs (reported): `lanes/profiler.md:122-130`, `:148`, `:291`, `:312`. `lanes/nblist.md:13-21`, `:55`, `:84-111` (job2 `NB_TIME` knob scan; raw per-phase records `job2-times.txt` in the nblist lane's Studio dir). `lanes/dispatch.md:31`.
- Code at 163f2838e (verified): `MetalNonbondedUtilities.cpp:50-75` (`NB_TIME`), `:96-97` (2400 x 64 computeNonbonded launch), `nonbonded.metal:239-253`, `:322-344`, `:434-441`, `:451-495`; `common.metal:57-67` (64-bit atomicAdd as one or two 32-bit atomics).
- Scripts (research-data/findblocks-emu/): `emu3.py` and `emu3-out.txt` (list-shape counts), `fit.py` and `fit2.py` (cost fit, leave-one-out, predictions), `age.py`, `lsort.py`, `means.py` (read the job2 records).
- Pall, Zhmurov, Bauer, Abraham, Lundborg, Gray, Hess, Lindahl, "Heterogeneous parallelization and acceleration of molecular dynamics simulations in GROMACS", J. Chem. Phys. 153, 134110 (2020), arXiv:2006.09167, sections V.B, V.D, V.E, V.F (verified in the PDF).

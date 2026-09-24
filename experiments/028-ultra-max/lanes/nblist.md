# Nblist lane

Goal: cut the neighbor list build on the M3 Ultra: findBlocksWithInteractions, sortShortList2, computeRange, the block bounds and sort kernels, and the rebuild policy.

## State

- Worktree /Users/amir/code/mini/ultra-nblist. Branch ultra/nblist (clean wins, from 6df2b8bcb) and ultra/nblist-dev (lab commit with env knobs for screens, never merged).
- Studio dir /tmp/openmm-metal-bench/ultra-nblist (build.sh tree of the dev branch).
- Dev knobs (defaults in brackets, base behavior in parentheses): `NB_SORT2` [1] (0) new SIMD short sort; `NB_SORT2_COPY` [1] (0) copy back with a compute kernel instead of a blit; `NB_RANGE_BLOCKS` [4 x cores] (1) computeRange threadgroups; `NB_BATCH` [1] findBlocks warps per block row; `NB_FBTG` [32] findBlocks threadgroup size; `NB_PAD` [80] padding in thousandths of the cutoff.

## What the profile says (profiler p1, counters mode, us per step)

| Test | findBlocks | per rebuild | sortShortList2 | computeRange | PME sort (assign+copy+positions+buckets) |
|---|---:|---:|---:|---:|---:|
| rf | 153 | 284 (50%) | 48.5 | | |
| pme | 138 | 240-280 (54%) | 48.5 | 20 (PME sort) | 19 |
| apoa1rf | 290 | 518 (71%) | | 18.5 (block sort, clear only) | |
| apoa1pme | 345 | 464 (75%) | | 78 | 86 |
| apoa1ljpme | 242 | 444 (50%) | | 250 | 237 |
| cellulose | 1007 | 1488 (66%) | | 258 | 368 |
| stmv | 2054 | 1983 (50%) | | 639 | 1356 |

sortShortList2 (737 keys, 12 x 64 threads) and computeRange (one threadgroup since 9074c38f1) are single-core launches on a 60-core GPU.

## Log

### 20:40Z first dev build

Changes in the dev commit 09b4b4f67:

1. sortShortList2: one SIMD group per element counts the keys that sort before it (simd_sum), 737 x 32 threads instead of 12 x 64 threads each scanning all 737 keys. The copy back is a compute dispatch instead of a blit, which kept a blit encoder in every small-system step.
2. computeRange: every threadgroup writes its own min and max, and each SIMD group of assignElementsToBuckets combines them with simd_min and simd_max. No cross-threadgroup visibility is needed, which was the 9074c38f1 bug. The `counters` buffer goes away.
3. Knobs for the findBlocks batch (HIP uses 4 below 2000 blocks; Metal has 1 and a METAL-TODO), its threadgroup size, and the padding (CUDA and HIP 0.08, OpenCL 0.1).

### 21:05Z clean commits and more knobs, waiting for the lease

- Clean branch ultra/nblist: ec464a484 (SIMD short sort plus compute copy back) and e342bc02f (computeRange with 4 threadgroups per core, combined in assignElementsToBuckets). Not yet built or gated.
- Dev branch adds lab knobs `NB_MAXBITS` (single-pair cutoff, base 4 below 100k atoms), `NB_PAIRBUF` (collect single pairs in threadgroup memory and bump interactionCount[1] once per buffer instead of once per candidate block), `NB_PREFETCH` (look up each candidate's atom block and center when it is collected, and load the next candidate's positions while the current one is checked), and `NB_TIME=<file>` (each nblist phase and the nonbonded kernel in its own command buffer, GPU time appended to the file).
- Hypothesis for findBlocks' 280 us on 737 blocks: the kernel is bound by the longest block rows (the upper triangle gives row 0 all its neighbors), each candidate costs two dependent global loads, and every candidate with single pairs does a global atomicAdd on one counter.
- Trees on the Studio: `ultra-nblist` (dev 9c253281c), `ultra-nblist/t2` (cf1db26b5), `ultra-nblist/t3` (fa950ac66, all knobs). job2 (timings of 12 configs on pme, rf, apoa1pme, apoa1ljpme, then a short ns/day scan) is queued on t3 behind 20 or so lease tickets. I lost an earlier queue slot at 20:58Z by replacing scan1.

### 21:12Z one lease slot for everything

- The clean branch (e342bc02f) is built in `ultra-nblist` (BUILT 21:04:44Z). `t3` stays the knob tree.
- RULES.md now asks for one outstanding lease request per lane, with ab.sh bundled inside it. I stopped my separate gate waiter and removed a stale ticket of mine (`ultra_nblist-9040`), whose pid had been reused by another lane's ab.sh and so looked live.
- job2 (ticket 59753, about 15th in the queue) now runs, in one hold: gate.sh --quick on the clean build, the RULES.md screen (2 x 15 s, six tests) against ultra-base, then per-phase GPU times of the knobs on pme and apoa1pme with what is left of the 20 minutes.
- The lease is held by hand (no pid file) by another lane since 21:08Z; reported to the lead.

### 21:30Z three more clean commits, lease queue stuck

Clean branch ultra/nblist, built as tree `t4` (411a9f19a):

1. ec464a484 sortShortList2 with one SIMD group per element, compute copy back.
2. e342bc02f computeRange with 4 threadgroups per core, combined in assignElementsToBuckets.
3. 0669fddab findBlocks rows of equal length: row i compares block i with the next NUM_BLOCKS/2 blocks in sorted order, wrapping past the end, instead of every later block. Row 0 used to scan all 737 blocks on dhfr while the last rows scanned almost nothing, and with one SIMD group per row on a 60-core GPU the kernel lasted as long as row 0. Each pair still lands in exactly one row (the pair half the list apart goes to the lower row when the count is even); a large block that the wrap cuts short is always checked. 15 lines.
4. a96b568fa assignElementsToBuckets adds to a bucket once per SIMD group (the lanes that share a bucket take consecutive offsets from one atomic). The PME atom sort input is in spatial order, so a SIMD group's 32 atoms mostly share one or two buckets. 21 lines.
5. 411a9f19a computeBucketPositions scans with simd_prefix_inclusive_sum, three barriers per chunk of 1024 buckets instead of twenty. 23 lines.

Dev tree `t3` (163f2838e) has knobs for all of them (`NB_WRAP`, `NB_SORTAGG`, `NB_SORTSCAN`) and times the long-list sort path as `lsort<length>` under NB_TIME.

job2 now gates t4 (falls back to the sort-only build if t4 fails), screens it against ultra-base, then times 15 knob configs on pme, apoa1ljpme and apoa1pme. Nothing has run yet: since the new lease.sh went in (21:02Z), no new-format ticket has been served. The head of the FIFO is four tickets from the old lease.sh, whose processes don't take turns the same way. Reported to the lead at 21:26Z.

### 23:05Z first screen: the sort pair wins, the bucket-sort pair breaks forces

job2 got the lease at 22:55Z, after two hours in the queue.

- Quick gate of the five-commit stack (t4, 411a9f19a): FAIL. gbsa and rf pass. pme, apoa1rf, apoa1pme and apoa1ljpme fail with rel|dF| 13 to 32, in both precisions. rf and pme share one system and one findBlocks path. What only pme adds is the PME atom sort, which takes the long sort path (23,558 elements). So a96b568fa (one atomic per bucket per SIMD group) or 411a9f19a (the SIMD bucket scan) breaks the long sort. apoa1rf also sorts its 2,882 blocks on the long path, and it runs the large-block wrap code too. I can't see the bug on paper yet. diag1 (forces.py on the dev tree with `NB_SORTAGG`, `NB_SORTSCAN` and `NB_WRAP` one at a time) is queued as a correctness ticket.
- Quick gate of e342bc02f (short sort plus computeRange): PASS, rel|dF| equal to ultra-base to 4 digits on all 12 rows.
- Screen of e342bc02f against ultra-base, 2 rounds of 15 s, Metal single, host clock (benchmark.py). Load 3.0 to 8.6, 6 of 24 runs overlapped a build:

| test | base ns/day | e342bc02f | ratio (round range) |
|---|---|---|---|
| gbsa | 1244.16 | 1296.56 | 1.042 (1.041 to 1.043) |
| rf | 711.61 | 772.98 | 1.086 (1.064 to 1.109) |
| pme | 538.21 | 593.03 | 1.102 (1.101 to 1.102) |
| apoa1rf | 300.23 | 300.55 | 1.001 (1.000 to 1.002) |
| apoa1pme | 194.46 | 200.49 | 1.031 (1.030 to 1.032) |
| apoa1ljpme | 144.79 | 160.51 | 1.109 (1.101 to 1.116) |

- These two commits are the candidate: ultra/nblist now points at e342bc02f, pushed to mini. The other three moved to ultra/nblist-wip. Lines: ec464a484 29 added and 21 removed, e342bc02f 24 added and 46 removed. The full gate is queued bare (23:01Z).
- The research lane's findBlocks study (research/2026-09-25-metal-native-findblocks-design.md) says not to ship the wrap commit alone: in its emulator, the large blocks at the end of the size order take over the longest row. It proposes a batch picked from rows per core, plus prefetch, an unrolled mask and flush-time single pairs. job2's knob scan is its K1 and part of K2.
- scan.py now pins `NB_SORTAGG=0` and `NB_SORTSCAN=0` for every config, so a broken sort doesn't skew the findBlocks timings.

### 23:12Z knob scan: batch 4 holds up, wrap and prefetch are dead

job2's second half timed each knob on the dev tree (t3, 163f2838e) with `NB_TIME`: every nblist phase in its own command buffer, GPU time per kernel, one run of 1.5 s per config, all with the bucket-sort knobs off. `find/rebuild` is the median findBlocks time on steps that rebuild (above 100 us), `exit` the median on steps that return early, `nonbonded` the mean computeNonbonded time. `new` is the candidate (short sort plus computeRange over 4 threadgroups per core); every other row is `new` plus one knob. agg0 and scan0 equal `new` by construction, so they give the noise: 1 to 1.5% on find/rebuild.

| config | pme find/rebuild | pme nonbonded | apoa1pme find/rebuild | apoa1pme nonbonded | apoa1ljpme find/rebuild | apoa1ljpme nonbonded |
|---|---|---|---|---|---|---|
| new | 280.7 | 124.4 | 619.9 | 423.1 | 788.6 | 446.6 |
| base (old sort paths) | 268.5 | 123.9 | 544.9 | 421.4 | 571.2 | 446.0 |
| batch 2 | 214.2 | 124.6 | 546.2 | 424.1 | 697.3 | 456.0 |
| batch 4 | 160.6 | 127.8 | 505.2 | 429.1 | 638.4 | 474.2 |
| wrap | 245.5 | 129.4 | 827.9 | 450.0 | 845.9 | 466.5 |
| wrap, batch 4 | 164.1 | 133.3 | 548.4 | 459.9 | 655.7 | 493.4 |
| pair buffer 128 | 260.0 | 123.8 | 660.0 | 422.6 | 755.0 | 445.3 |
| prefetch | 287.5 | 124.3 | 632.7 | 423.0 | 804.1 | 446.4 |
| threadgroup 64 | 280.8 | 124.6 | 621.3 | 423.6 | 795.1 | 446.4 |
| MAX_BITS 0 | 230.2 | 106.4 | 545.2 | 367.5 | 719.6 | 545.2 |
| padding 0.12 | 292.2 (rate 0.36) | 120.1 | 647.6 (0.36) | 397.2 | 814.0 (0.35) | 473.3 |
| padding 0.16 | 303.9 (rate 0.30) | 117.4 | 675.8 (0.29) | 388.5 | 845.5 (0.29) | 507.4 |

The rebuild rate is 0.50 on every row without a padding change.

- Batch 4 on pme (737 blocks) cuts findBlocks per rebuild by 43% (280.7 to 160.6 us), at a 3% nonbonded cost from the longer lists it writes. That supports nonbonded's tiles rule 6d72c3ae9, which picks batch 4 there. On apoa1 (2882 blocks, above that rule's cut) batch 4 gains less and costs more nonbonded, which fits the rule leaving it at 1.
- Wrap is dead. Alone it gains 13% on pme but loses 34% on apoa1pme and 7% on apoa1ljpme, as the research emulator predicted; at batch 4 it adds nothing on pme (164.1 vs 160.6) and costs 4% nonbonded. So I won't build the wrap-on-6d72c3ae9 tree (w4) the lead asked about; this is the same comparison.
- Prefetch is 2 to 3% slower everywhere and threadgroup 64 changes nothing. Both dead. The pair buffer gains 7% on pme and 4% on apoa1ljpme but loses 6% on apoa1pme: not worth a commit at that spread.
- MAX_BITS 0 (no single pairs) is the interesting one: nonbonded drops 14% on pme and 13% on apoa1pme and findBlocks drops too, but apoa1ljpme nonbonded rises 22%. It needs a real screen before any size or force-type rule.
- Padding above 0.08 lowers the rebuild rate (0.50 to 0.36 and 0.30) and makes nonbonded cheaper on pme and apoa1pme, though each rebuild costs more. This ran at batch 1; the research study expects batching to cut the case for more padding. It would also need the md100 check and an M2 memory look, so it waits until batch 4 is merged.
- The apoa1 gap between `new` and `base` (620 vs 545 and 789 vs 571 us) is not a sort bug. The block sort keys are `(bin<<BIN_SHIFT)+block`, all distinct, so every correct sort yields the same order, and the non-uniform path only uses computeRange to clear bucketOffset. findBlocks gets the same input in both configs. The early-exit time also moved (apoa1ljpme exit 8.4 us in `base`, 26.9 in `new`, while apoa1pme reads 26.9 in both), which points at the process or clock state, not the kernel. One 1.5 s run per config can't separate that, so the fresh-process check stays on the list.
- Side finding: the early exit of findBlocks costs 27 us on apoa1 and 6 us on pme, on half the steps, because every threadgroup still launches with its full threadgroup memory. On apoa1pme that is about 1.5% of a step. It belongs to the gated rebuild chain (roadmap 7a) or dispatch's indirect skip.

Per-commit screen on cand2 (lead, 23:08Z): n2a (17929e631 + ec464a484, f7d307c3d) builds in `t2`, n2b (n2a + e342bc02f, a6f97e3b6) in `t4`. Both are local branches (ultra/nblist-n2a, -n2b) made with git merge-tree, no conflicts; they're lab trees and won't be pushed.

### 23:24Z dev2 tree on the pme merge base, three more jobs queued

- New dev branch ultra/nblist-dev2 (8eb9895b8, lab only) = n2b + one knob commit, built as `t5`. It keeps the live knobs (`NB_MAXBITS`, `NB_BATCH`, `NB_PAD`, `NB_TIME`) and drops the dead ones. New:
  - `NB_TIME_WAIT=1` waits for the GPU before and after each timed phase. job2's split showed alternating steps where bounds, sortBoxData and the block sort ran 2.5x slower (apoa1pme: 70 vs 28 us for bounds). That pattern points at other command buffers overlapping the timed one, so the job2 per-phase numbers on apoa1 are upper bounds.
  - `NB_UNROLL=<n>` (K3): when at least n atoms of block X pass the sphere test, test all 32 with an unrolled fma loop over `posBuffer` and AND the result with the sphere mask. Same bits as the ffs loop. 33 (the default) compiles the code out.
  - `NB_STAGEBOX=1` (K4): each 64-thread sortBoxData threadgroup loads the centers and sizes of its 95-block window into threadgroup memory once; the 31-step large-block loop then reads threadgroup memory.
- Offline kernel check: `mslcheck.py` (scratch dir) builds the findInteractingBlocks module source the way `MetalContext::createModule` does and compiles it with `xcrun metal`, CPU only. All knob combinations compile, with and without periodic boxes and large blocks.
- Queued: diag2 (correctness hold: forces with `NB_UNROLL=0`, `NB_STAGEBOX=1`, MAX_BITS 0 plus unroll, batch 4 plus unroll; md100 at MAX_BITS 0 and 2), job3 (timing hold: isolated phase times for K3 on gbsa, rf and pme at batch 1 and 4, and for K3 and K4 on apoa1rf and apoa1pme), screen-mb (ab.sh, MAX_BITS 4, 2, 1, 0 on pme, rf, dhfr, apoa1pme, apoa1rf, apoa1ljpme, 2 x 15 s). Queue depth is 57 to 59, about 3 hours.
- Why MAX_BITS matters on Metal: every single pair costs six 64-bit fixed-point atomicAdds in computeNonbonded, and common.metal emulates each with two 32-bit atomics. Tiles pay three per atom per tile, not per pair. HIP's rule (4 below 100k atoms for RDNA) was tuned for hardware 64-bit atomics.

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

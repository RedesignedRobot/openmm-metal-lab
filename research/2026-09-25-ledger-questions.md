# Ledger questions settled from primary sources

2026-09-25, research lane. No GPU time. Each answer marks its tier: verified (I read the code, the doc, or ran a compile or a CPU emulation), reported (a lane log says so), or inference (my reasoning). Supporting files are in `research-data/ledger-q/` (the compile test, the SHAKE emulation and its output, and every forces row on the Studio).

## 1. Waitfree capacity bound with tiles per batch above 1 and wrapped rows

Answer: the old bound holds for any NUM_TILES_IN_BATCH and for 0669fddab's wrapped rows. The a08243d4b reviewer is right. The design doc's `totalTiles + numAtomBlocks x batch` (metal-native-design.md:126, :423) is a valid but loose bound: it charges every warp a partial tile of its own that the proof below shows is already paid for.

Proof (verified against findInteractingBlocks.metal at 0669fddab; line numbers from that file):
- One warp handles one row share: `block1 = startBlockIndex+warpIndex/NUM_TILES_IN_BATCH` (:337), and its buffer starts empty (`neighborsInBuffer = 0`). The B warps of a row walk disjoint 32-wide chunks of block2 (:386, start offset `warpIndex%NUM_TILES_IN_BATCH`, stride `warpSize*NUM_TILES_IN_BATCH`).
- Each candidate block2 puts at most 32 atom2 slots into the warp's buffer, one per atom2 with more than MAX_BITS_FOR_PAIRS interacting block1 atoms. Mid-loop flushes store `neighborsInBuffer/warpSize` full tiles (:586-602) and the end-of-row flush stores `ceil(neighborsInBuffer/TILE_SIZE)` (:615-630). So a warp that collected S slots from C contributing block2s writes ceil(S/32) tiles, and ceil(S/32) <= C.
- Summed over the row's B warps: tiles per row <= contributing block2s per row <= row length.
- Rows cover each unordered block pair once. Triangle: row block1 takes block2 > block1. Wrap (:384): row lengths are NB/2 for block1 < NB/2 and NB/2-1 above when NB is even, (NB-1)/2 when odd; a pair at distance exactly NB/2 belongs only to the lower row. Wrapped indices are distinct within a row because the row spans fewer than NB blocks (:432-433). The large-block forced include (:416) only stops a chunk from being skipped; it adds no candidates.
- Total tiles <= NB(NB-1)/2 < numTiles = NB(NB+1)/2 (setAtomBlockRange, a08243d4b MetalNonbondedUtilities.cpp:519-521), which is the maxTiles waitfree allocates (:265-267).
- Single pairs: an atom2 goes to singles only with at most MAX_BITS_FOR_PAIRS pairs, so a (row, block2) pair adds at most 32 x MAX_BITS. Total <= 32 x MAX_BITS x NB(NB-1)/2 < maxPossiblePairs (:261). Also independent of batch and wrap.

Why it matters: both stores are bounds-checked (:564 singles, :594 and :621 tiles), so an overflow drops interactions silently instead of corrupting memory, and under waitfree the host reads the count only on reorder steps (:436, :465). The proof is what makes that safe.

The 314 of 326 MB admission margin (dispatch.md:39) does not depend on this question. The design doc's extra term would add NB x B x 132 B, 0.39 MB at 737 blocks and B = 4. The real exposure is that admission reads `recommendedMaxWorkingSetSize - currentAllocatedSize` once at init (:262-263): a process holding about 3 GB more (the 12 MB margin x 256) when it creates the context gets the poll path on rf, pme and dhfr. That's a performance cliff, not a correctness risk (inference).

## 2. Untracked buffers and concurrent passes (OQ2)

Answer: untracked buffers are not a prerequisite for any concurrency the lanes plan. Close OQ2 and correct the playbook (:19, :200, :308, :543). The design doc (metal-native-design.md:636) holds for separate passes. For a concurrent encoder both documents missed the actual rule: tracking does nothing inside it, in either direction.

Separate passes, tracked buffers (verified doc, reported measurement):
- Apple, MTLHazardTrackingMode.tracked: "When at least one command writes to a tracked resource, the framework takes the following actions: Delay write operations until all previous read operations finish. Prevent subsequent commands from running until write operations finish." Only conflicting commands wait.
- Apple, Resource synchronization: "By design, GPUs can run multiple commands in parallel", and the framework synchronizes "for the commands you submit to an MTLCommandQueue instance, and only for the resources that" are tracked and bound directly to an encoder.
- Measured on the M3 Ultra (pme.md 22:35Z, profiler counters records): the PME chain starts while the list build still runs, across a command-buffer boundary, though both read posq. Overlap medians 26 us on pme, 353 on apoa1pme, 1508 on cellulose. The profiler's encoder unions run 1 to 27% below their sums (profiler.md:26).

One concurrent encoder, tracked buffers (verified doc and code, reported measurement):
- Apple, MTLDispatchType.concurrent: "If you encode multiple commands that access a single resource, you're responsible for synchronizing the memory operations to that resource."
- dispatch probe1 (dispatch.md 19:58Z): a concurrent encoder with no barriers gave gbsa rel|dF| 0.85, rf 0.83 and a GPU page fault on pme. I checked the probe tree on the Studio: its MetalArray.cpp:55 allocates with `MTL::ResourceStorageModeShared` only, so every buffer was tracked. Tracking did not serialize those dispatches and did not protect them.

What untracked could still buy (not verified): removal of whole-resource false dependencies (Apple tracks per resource; the pmeForce array exists to dodge exactly this on forceBuffers), lower CPU encode cost (unmeasured), and nothing for a second queue: Apple scopes automatic synchronization to one MTLCommandQueue and points to events across queues, so cross-queue tracking is undocumented and the platform's MetalEvent stays the correctness mechanism.

Practical rule: keep tracked buffers. Split passes where there is no write conflict and let Metal overlap them. Inside a concurrent encoder, only memoryBarrier calls give correctness (dispatch's auto mode). OQ1, the scope of memoryBarrier(resources:), stays open.

## 3. MSL 4.1 atomic ordering

Answer: api-check item 4 is right. The playbook (:218, :306, :503, :539) and ledger :80 are wrong for MSL 4.1: fetch-and-modify atomics take acquire, release and acq_rel when the call passes a mem_flags argument. Only the 3-argument form is relaxed-only.

- The spec contradicts itself. Section 6.16.1 says "In Metal 4.1 and later, you can specify memory_order values for atomic operations, atomic_thread_fence, threadgroup_barrier, and simdgroup_barrier" (MSL spec 2026-06-04, p. 300). The same section keeps "For atomic operations other than atomic_thread_fence, memory_order_relaxed is the only enumeration value" (p. 299), and 6.16.4.5 keeps "The only supported value for order is memory_order_relaxed" (p. 306). The last two read as pre-4.1 text left in place. The playbook quoted them.
- The header settles it (verified, metal_atomic in the M3 Ultra's MetalToolchain 27.2, build 32023). Line 566 defines `METAL_RELAXED_ORDER(O)` with the message "argument must be 'metal::memory_order_relaxed' if no 'mem_flags' argument is provided". It is attached to the 3-argument overloads only, for example `atomic_fetch_add_explicit(device _atomic<T, S> *object, U operand, memory_order order)` at :1884. The 4-argument overload at :1877 passes `int(order)` straight to the builtin. Plain `atomic_fetch_add` (:1891) calls it with memory_order_seq_cst and all memory flags.
- The compiler agrees (verified, `atomics41.metal`, IR only, nothing written). Under `-std=metal4.1`, `atomic_fetch_add_explicit(c, 1u, memory_order_acq_rel, mem_flags::mem_device)` lowers to `air.atomic.global.add.u.i32` with order operand 4. An acquire load gets 2 and a release store gets 3. The 3-argument call with acq_rel fails with "no matching function". Under metal3.2 and metal4.0, memory_order_acquire, release and acq_rel are undeclared identifiers.
- Consequence: nothing changes today, because the platform compiles at LanguageVersion3_2 (MetalContext.cpp:483 at 6df2b8bcb) and 4.1 needs macOS 27. At 3.2 the pattern stays a seq_cst device fence, a relaxed fetch_add and another seq_cst fence, because acquire and release are undeclared there (common.metal:15's `__threadfence` is that fence). After a 4.1 bump, one acq_rel fetch_add with mem_flags::mem_device is legal. The IR carries the order; whether the AGX backend emits anything cheaper than the fence pair is unverified and needs a litmus test.

Proposed ledger :80 wording: "Fetch-and-modify atomics are relaxed-only at MSL 3.2 and 4.0 and in 4.1's 3-argument form; 4.1's (order, mem_flags) overloads accept acquire, release, acq_rel and seq_cst (metal_atomic:566, :1877; compile check). The platform compiles at 3.2."

## 4. rel|dE| between repeats

Answer: each claim is right for some tests. Single-precision rel|dE| moves by 3 to 16% on most tests and up to 51% on apoa1rf; mixed does not move at all. infra's "about 30%" came from two repeats and is low for apoa1rf. forces.py's "factor of 2" (forces.py:6-7) is higher than any repeat measured. The gate uses 10x (forces.py:5), so both sit inside it.

Data (verified): every forces run on the Studio (`/tmp/openmm-metal-bench/*/forces*.txt`, 9 files), rows whose rel|dF| matches the CLT baseline to 4 digits. "base" is the 4 ultra-base runs (CLT, repeat, gate, beta). "all" adds same-force rows from the plugins, nblist and mixed gates.

| test | single max/min, base (4) | single max/min, all (7 or 8) | single absolute spread | mixed, base (4) |
|---|---|---|---|---|
| gbsa | 1.07 | 1.16 | 9.3e-08 | identical |
| rf | 1.11 | 1.15 | 2.9e-08 | identical |
| pme | 1.05 | 1.07 | 7.5e-08 | identical |
| apoa1rf | 1.40 | 1.51 | 2.0e-08 | identical |
| apoa1pme | 1.03 | 1.05 | 3.2e-08 | identical |
| apoa1ljpme | 1.14 | 1.14 | 8.3e-08 | identical |

Mechanism: the absolute spread is 2 to 9e-8, about one float ulp of the total energy (2^-24 = 6e-8), on every test. The relative swing is that noise over the systematic Metal-against-Reference error, so it's largest where the error is smallest: apoa1rf sits at 4 to 6e-8 and swings 40 to 50%, pme sits at 1.2e-6 and swings 5 to 7%. Single sums energy into a float energyBuffer and mixed into a double one (MetalContext.cpp:341 and :335 at 6df2b8bcb, verified). findBlocks appends tiles through atomicAdd on interactionCount[0] (findInteractingBlocks.metal:592, :619), so which tiles each thread sums, and in what order, changes every run (inference; it fits mixed being stable to 4 digits).

Use: single rel|dE| only catches breakage. Mixed rel|dE| repeats exactly, so on a build that leaves list content and energy math alone, any mixed change is real. A build that changes list content (wrap, batch, sort order) may shift mixed rel|dE| at the third digit without being wrong: nblist t4's gbsa and rf rows passed forces with mixed rel|dE| 6.338e-07 and 2.115e-07 against base's 6.124e-07 and 2.094e-07.

## 5. Why mixed c3 (SHAKE warm start) cost SHAKE accuracy

Answer: c3 never broke the tolerance. It changed where accepted constraints land inside the tolerance band. Base SHAKE mostly exits far below tol; c3 leaves many constraints spread across the band, so the largest length error in a frame edges toward the same ceiling. The ceiling itself comes from the float constraint length, not from SHAKE.

- Base (integrationUtilities.cc at 6df2b8bcb): a constraint is corrected only while `|residual| >= d2*tol` (:156-157), inside a 15-iteration Gauss-Seidel loop (:151). Corrections are Newton steps from large starting residuals, so most constraints finish well under tol*d2.
- c3 (933483458, :162): a float loop first iterates to `max(tol*d2, 1e-7*d2)`. At tol 1e-8 that stops at 10x the tolerance, and the mixed loop then leaves alone every constraint already under tol*d2. Those constraints keep float-stage residuals anywhere in [0, tol*d2).
- The target length is float: IntegrationUtilities.cpp:275 stores `(float) (cluster.distance*cluster.distance)` and the kernel reads `float d2 = params.z` (:122). Rounding d^2 to float moves d by up to 2^-25 relative, about 3e-8. So the ceiling on relative length error is that rounding plus tol/2, about 3.5e-8 at tol 1e-8. Base's 2.26e-8 (mixed.md:148) sits under that ceiling, and SETTLE's 2.5e-8 and 3.1e-8 come from the same float lengths (mixed.md:127-128).
- CPU emulation (verified by run, `shake_emu.py`, double for mixed, float32 for real, C-H 0.109 nm, 4000 clusters, 1 and 3 H per carbon):

| tol 1e-8 | exit residual/tol, median | p90 | mixed iterations | rel length error p99 | max |
|---|---|---|---|---|---|
| base, 1 H | 0.000 | 0.126 | 3.77 | 1.951e-08 | 2.024e-08 |
| c3, 1 H | 0.181 | 0.661 | 1.21 | 1.984e-08 | 2.024e-08 |
| base, 3 H | 0.074 | 0.605 | 5.46 | 1.977e-08 | 2.024e-08 |
| c3, 3 H | 0.097 | 0.666 | 1.96 | 1.985e-08 | 2.025e-08 |

At tol 1e-5 the two distributions match (shake-emu-1e-5.txt), as the lab measured (4.96e-6 against 4.98e-6, mixed.md:126). The measured growth at 1e-8 for g1 is pme 2.26e-8 to 2.32e-8 on the M2 and 2.33e-8 on the M3 Ultra, and gbsa 2.26e-8 to 2.30e-8 on the M2 and 2.25e-8 to 2.57e-8 on the M3 Ultra (mixed.md:148, :194, :201). That is 0.06 to 0.32e-8, always under tol/2 = 0.5e-8. The earlier c1-c4 stack measured 2.26e-8 against 2.25e-8 (mixed.md:126-127), no loss at all. Both fit a finite-sample max over one frame that lands closer to the band edge more often, not a systematic error (inference). Emulation caveat: Metal's mixed is df64 (about 48 bits), not IEEE double. That doesn't change the band argument.

If c3 is ever revived, forcing one mixed correction on every constraint after the float stage should restore base's distribution for one extra mixed iteration (inference, untested). It's dropped from g2 (5cc0ba5af) at a cost of at most 0.6% (mixed.md:206), so no action.

## 6. findBlocks per-block cost on stmv

Answer: the lead's arithmetic is right. metal-native-design.md:177 ("dhfr costs 0.38 us per block and stmv 0.12") used raw counters-mode per-rebuild times, which count overlapped time twice. Corrected: dhfr about 0.26 us per block, stmv 0.060.

- Per rebuild, raw over attributed (profiler.md 22:25Z correction): dhfr 270 over 188 us, stmv 3999 over 2000. Buffers mode (findblocks design :20): dhfr 200, stmv 2047. nblist.md:21's 1983 agrees with the attributed figure.
- Blocks: 23558/32 rounds up to 737, 1066628/32 to 33333. So 0.38 x 737 = 280 and 0.12 x 33333 = 4000, both raw. Attributed: 188/737 = 0.255 and 2000/33333 = 0.060. Buffers mode: 0.271 and 0.061.
- The doc's argument, that a serial longest-row chain makes small systems pay more per block, gets stronger: 4.3x per block instead of 3.2x. The sentence should read "dhfr costs about 0.26 us per block and stmv 0.06 (attributed per-rebuild time)".

## Pointers

- findInteractingBlocks.metal at 0669fddab, :337, :384-433, :586-630: the loop and flushes the capacity proof rests on.
- a08243d4b MetalNonbondedUtilities.cpp:252-273: waitfree admission and bounds.
- developer.apple.com/documentation/metal/mtldispatchtype/concurrent and /mtlhazardtrackingmode/tracked: the two sentences that settle OQ2.
- metal_atomic in the MetalToolchain 27.2 cryptex on the Studio, :566, :1877-1891: the 4.1 ordering rule.
- research-data/ledger-q/forces-all.txt: every forces row on the Studio, for re-deriving the rel|dE| table.

# Lane: atomics (force accumulation)

Worktree /Users/amir/code/mini/ultra-atomics, branch ultra/atomics off 6df2b8bcb. Studio scratch /tmp/openmm-metal-bench/ultra-atomics. Started 2026-09-24 19:23Z. No end time (lead, 22:40Z): the lane runs until the lead says stop.

## How accumulation works today

- Forces go into one long long fixed-point buffer (scale 2^32, x/y/z planes of PADDED_NUM_ATOMS). Consumers read it directly.
- `platforms/metal/src/kernels/common.metal` emulates the 64-bit add with two 32-bit atomics: a returning `atomic_fetch_add` on the low word, carry detected from the old value, then a non-returning add on the high word only when the high part is nonzero. Negative values always take both atomics unless the low add carries.
- Energy has no atomics: every thread owns a slot in energyBuffer, reduced by reduceEnergy.
- Users: nonbonded.metal (6 per tile per lane, 6 per single pair), BondedUtilities (3 per atom per bonded term), PME interpolation (3 per atom with the PME stream), GBSA/custom GB, CustomCentroidBond and plugins. PME charge spreading uses hardware float atomics in single and mixed (fixed point only for double or deterministicForces).

## Native 64-bit atomics

MSL 4.1 spec (2026-06-04), section 6.16.4.6: atomic_ulong supports only `atomic_max_explicit` and `atomic_min_explicit`, relaxed order, device memory, void return. There is no 64-bit fetch_add in MSL on any family. That option is dead.

## Log

### 19:30Z microbenchmark (ub.mm, nonbonded-like write pattern, 288k tiles, 55M 64-bit adds)

- `atomic_fetch_add_explicit` on `device atomic_ulong` does not compile on the M3 Ultra (Apple9 true): no matching function. Confirms the spec.
- Pure atomics: current emulation 1480 us, one non-returning 32-bit atomic 880 us, plain RMW 220 us. All correct orderings (batched low words, carry deferred to the next tile) equal the emulation: the atomic unit's op count is the limit, about 37 G emulated adds/s.
- With 400 FMAs per tile: emulation 2630, batched 2596, deferred 2490, one atomic 2430 us.

### 19:55Z force-eval floor on real kernels (forcetime.py: Verlet 1e-9 ps, no constraints, 300 evals x 5, 2 rounds, Metal single)

ms per force evaluation, ratio base/variant:

| test | base | defer carry | 1 atomic (wrong) | plain RMW (wrong) |
|---|---|---|---|---|
| pme | 0.4775 | 0.999 | 1.276 | 1.325 |
| apoa1pme | 1.4829 | 1.003 | 1.408 | 1.795 |
| apoa1rf | 0.8181 | 0.988 | 1.645 | 1.741 |
| gbsa | 0.2409 | 0.979 | 1.051 | 1.055 |
| rf | 0.2864 | 0.993 | 1.192 | 1.187 |

Deferring the carry (latency hiding) gains nothing. Halving the atomic op count gains up to 1.65x. The lever is the number of atomic ops per force add, not their latency. Load was 3 to 3.9 (other lanes building).

### 20:00Z candidate: force words (one 32-bit atomic per add, bit-identical)

Five signed int32 words per force component, scales 2^32, 2^24, 2^16, 2^8, 2^0. A float with exponent e goes whole into word (e+9)/8 with one returning atomic, exactly (24 significant bits fit below 2^31). Signed overflow carries 2^24 into the next word, which is rare. A fold kernel after the nonbonded kernel adds sum(word[k] << 8k) into the long buffer and zeroes the words. Both this and realToFixedPoint truncate toward zero and wrap mod 2^64, so the sums should match base bit for bit, and the order of adds cannot change them (deterministic). Nonbonded kernel only for now: +48/-24 in 3 files plus the 55-line forceWords.metal. Memory cost 60 bytes per padded atom.

### 21:23Z force words: bit identity and force-eval screen (old CLT tree, 6df2b8bcb, plugin swap)

Force dump, one evaluation from a fresh Context on the 6 gate systems, single and mixed: forces identical to base bit for bit on all 12 (max|dF| 0). Energies differ by float rounding in single (|dE| 8e-4 on gbsa to 6e-2 on apoa1ljpme, about 2e-8 relative); the energy path is untouched, so this is the tile order from the neighbor list build. The dump ran without DeterministicForces; the next one sets it.

forcetime.py, Metal single, 300 evals x 5, 2 rounds interleaved, load 8.2 to 18.4, ratio base/variant:

| test | base ms | lo (1 atomic, wrong) | words |
|---|---|---|---|
| apoa1rf | 0.8228 | 1.654 | 1.114 |
| rf | 0.2909 | 1.019 | 1.069 |
| apoa1pme | 1.4845 | 1.400 | 1.005 |
| pme | 0.4816 | 1.267 | 0.992 |
| gbsa | 0.2451 | 1.056 | 0.983 |

Words keeps only a fifth of the one-atomic probe's gain on apoa1rf and nothing on PME. My reading: the returning low-word atomic, not the second atomic, carries most of the emulation's cost, and words still needs a returning atomic to see overflow. gbsa pays the fold dispatch (about 4 us). Not a keeper as is under the 1% rule (gbsa -1.7%).

### 21:29Z rebased on 71a602b43, commit 4be61f9b6

ultra/atomics fast-forwarded to pme's 71a602b43 (float atomic spreading). 4be61f9b6 adds words with a long-buffer fallback in forceWords.metal: words only when groupFlags != 0, the kernel is the default one, and 60 B/atom stays under 1% of recommendedMaxWorkingSetSize. Metal has no double precision (MetalPlatform::supportsDoublePrecision is false), so there is no double case to turn off. Memory: 60 B/atom against 24 B/atom for the long force buffer. stmv (1,066,628 atoms) needs 64 MB, apoa1 5.5 MB, cellulose 24.5 MB. On an 8 GB M2 the 1% cap (about 55 MB if its working set is about 5.5 GB; to be queried there) keeps stmv on the plain path. +122/-25 in 4 files. Full build under Xcode-beta started 21:29Z.

### 21:35Z queued: probe 1a, gate --quick, screen1

Probe 1a (profiler counters on apoa1rf, rf, apoa1pme and cellulose; base, 1 atomic, plain RMW and words plugins, one hold) plus the ub microbenchmark with a returning 32-bit atomic (k_ret) is job1, queued first. gate --quick on 4be61f9b6 and screen1 (words against p0 = 71a602b43, 2 rounds of 15 s on apoa1rf, rf, gbsa, pme and apoa1pme) are queued behind it. 9eb009703 adds a force-word carry test (TestMetalNonbondedForce: one atom overflows its 2^8 word, one overflows its 2^32 word), not yet built on the M3 Ultra main tree.

### 22:05Z chunked bonded kernel prototype (uncommitted, built in build-b)

Started ahead of probe 1a because the queue is about 25 deep. MetalBondedUtilities evaluates each bonded force in chunks of 64 terms, one per thread. Each thread stores its term's forces in a threadgroup pad. After a barrier, each atom the chunk touches sums its slots as 64-bit fixed point and issues one emulated 64-bit atomic per component. A host plan (CSR per chunk, ushort slots, one extra kernel argument) lists the atoms and slots. The sums are exact mod 2^64, so the force buffer should match base bit for bit. Common edit: BondedUtilities.h private to protected, initialize and createForceSource virtual. A force keeps per-term atomics when its terms have more than 4 atoms, its source contains continue, break or return, the plan saves less than a quarter of its adds, or the plan would pass Metal's 31-argument limit. A fresh-context review found the argument limit and the reuse case; both are fixed.

Atomic adds per force evaluation from the real topologies (chunkstat.py, CPU only), terms in their original order against sorted by lowest atom:

| test | slots (base adds) | chunk 64 | 128 | 256 | 64 sorted |
|---|---|---|---|---|---|
| apoa1rf | 727,206 | 132,218 (5.5x) | 117,248 (6.2x) | 109,301 (6.7x) | 5.6x |
| apoa1pme | 1,164,602 | 244,145 (4.8x) | 219,910 (5.3x) | 207,226 (5.6x) | 4.7x |
| cellulose | 4,216,950 | 1,255,493 (3.4x) | 1,133,239 (3.7x) | 1,072,074 (3.9x) | 4.3x |
| pme (dhfr) | 128,057 | 38,303 (3.3x) | 35,950 (3.6x) | 34,695 (3.7x) | 3.4x |

Chunks of 64 in the original order keep most of the reduction, so the prototype does no sorting and uses the default threadgroup size. Sorting helps only cellulose (3.4x to 4.3x). The design's 14x assumed chunks that mix forces; per force it is 3.3x to 5.5x. Queued: bonded check (ctest on the bonded tests plus a new 100k-bond multi-chunk test, then a force dump against the current build, bit for bit), chained to screen2 (cur against bonded, 2 x 15 s on apoa1rf, apoa1pme, cellulose, pme, gbsa).

### 22:13Z commit 45bf92869 (bonded chunks, local), branch pushed to mini

The mini is back; ultra/atomics (71a602b43, 4be61f9b6, 9eb009703) is pushed. 45bf92869 is the chunked bonded kernel: +230/-5 in 4 files (MetalBondedUtilities.cpp 176 lines with its license header, the 100,001-atom bond and angle chain test 37 lines). Added after the review: the plan is capped at 1% of recommendedMaxWorkingSetSize, like the force words. Plan memory is 8 B per chunk entry plus 2 B per slot, about 4.3 MB on apoa1pme and 18.5 MB on cellulose. build-b (src-b plus this commit) matches the worktree by git hash-object; its plugin is plugins-bonded. Not pushed until the bonded check passes.

### 22:20Z bonded moved to its own branch, check and screen split

On the lead's call, the bonded commit now sits alone on 71a602b43 as d8ab45b2b on ultra/atomics-bonded, pushed to mini. The message states the one common edit: BondedUtilities.h private to protected, initialize and createForceSource virtual. ultra/atomics is back at 9eb009703 (words and its test), so words and bonded screen and gate apart. build-b now builds both arms from src-b, with no install. plugins-b0 is 71a602b43 (md5 70577224) and plugins-bonded is d8ab45b2b (md5 8c0c255e). Before each arm builds, bb.sh checks every tracked file against the commit's git tree (symlinks skipped) and refuses untracked files. It also checks the dylib strings: b0 has neither foldForceWords nor bondedPad, and bonded has bondedPad only. The old chained check and screen ticket is gone. Queued at 22:20Z, about 30 deep: the bonded check as a --correctness hold (ctest on the bonded tests, then a force dump of b0 against bonded, bit for bit), then screen2a (apoa1rf, apoa1pme, cellulose) and screen2b (pme, gbsa, rf), each its own lease.sh hold, 2 rounds of 15 s, b0 against bonded. screen2.sh refuses to run unless both plugins still match bb.sh's md5s. Pid 72372 (infra's report) had already exited.

### 22:26Z words fold: where it can go, and a probe addition

No kernel that always runs reads the long force buffer between computeNonbonded and the integrator. MetalCalcForcesAndEnergyKernel::finishComputation runs bonded, nonbonded, the post computations, virtual sites and reduceEnergy. Only the first two always run. After them come the integrator kernels and getState, and those are common code, so folding there means editing every consumer. That leaves the lead's second choice, a gate on a system property. gbsa is CutoffNonPeriodic at 2.0 nm with a neighbor list, so a no-neighbor-list gate would not exclude it. Before picking the property, I need to know whether gbsa's -1.7% (and pme's -0.8%) sits in the fold dispatch or in the words nonbonded kernel. So job1 (not yet started) now also profiles gbsa and pme on base and words only, about 1.5 min more. Base arm check: plugins-p0 and plugins-prof carry the forceWords.metal source string because the cmake glob embeds it, but 71a602b43's MetalNonbondedUtilities never compiles or dispatches it. plugins-b0 (bonded screen) has no trace of it.

### 22:33Z queue reshuffled on the lead's order: 1a, then words, then bonded

Bonded (d8ab45b2b) now waits on probe 1a, so I dropped the two bonded screen tickets. Only the bonded --correctness check stays queued. I also dropped screen1: it was an unwrapped ab.sh whose per-run tickets requeue at the back, and the new words screen covers it. Words (4be61f9b6) has never been screened on 71a602b43. It is queued as two wrapped holds under 15 min each: wsa (rf, gbsa) and wsb (pme), 2 rounds of 15 s, three arms. ultra-base is at 6df2b8bcb, which lacks 71a602b43's PME spreading change. So the pme column needs p0 (71a602b43 nonbonded in the words tree) to isolate words, and ultra-base stays as the arm the lead asked for. wscreen.sh refuses to run if the words or p0 dylib md5 changed. Per the lead, the old rf words column (1.069, next to a lo-probe rf of 1.019 where an earlier run read 1.192) is noise until wsa repeats it. The monitor prints the 1a table when job1's process exits.

### 22:36Z keep rule covers both chips; M2 checks requested

The lead clarified RULES line 11: keep a change that gains 3% or more on at least one test on either chip, M3 Ultra or M2, and costs no more than 1% on any test on either. Words and bonded both need an M2 check before either is judged. I sent the lead words 4be61f9b6 (ultra/atomics) and bonded d8ab45b2b (ultra/atomics-bonded), both on mini, each against 71a602b43. The words gbsa gate waits on the M2 number too. On the M3 Ultra, gbsa's roughly 3,000 tiles barely fill the nonbonded kernel's 2,400 threadgroups (10 x 4 x 60 cores), so it is not atomic bound (1-atomic probe 1.051). On the M2 there are 400 threadgroups, so words may win there, and a gate that turns words off for gbsa would give that up.

### 22:45Z research pitfall check: both branches clean

Research read words and bonded against the code and found no pitfall. The word placement is exact, the carry is counted once per wrap, the fold is its own dispatch and clears the words, and the energy-only kernel writes no words. The bonded barriers sit in uniform flow, and LOCAL_SIZE is always 64. One follow-up for later: ultra/plugins (0b6380669) packs value arguments into one struct when a kernel passes 31 bindings. Once that merges, MetalBondedUtilities' argument count (9 fixed, 6 of them values) is conservative and turns chunking off for kernels that would still fit. That costs speed, not correctness, so I'll recount after the merge if bonded is kept.

### 23:03Z pid rule

RULES line 57: stop my own processes only by pids recorded at launch, never pkill, killall or a kill over a ps or pgrep match. Earlier kills today used explicit pids of my own lease tickets, but I found those pids with ps. From now on the Studio file ultra-atomics/pids.txt records each job's pid at queue time, and a ticket's name ends in its lease.sh pid. Every kill comes from that file.

### 23:08Z profiler: raising the grid cap buys nothing

Profiler raised executeKernel's cap from 12 to 24 thread blocks per core (720 to 1,440 groups). benchmark.py, 2 x 15 s against the same build: gbsa 1.005, rf 0.993, pme 0.997, apoa1pme 1.010. computeBondedForces runs at the 720 x 64 cap, but more groups alone do not help. A per-kernel census of that probe is queued as 91086. If computeBondedForces moves little there, the bonded kernel is limited by its atomic op count or memory traffic, not by occupancy, which is the case the chunked kernel targets.

### 23:18Z probe 1a result (counters, M3 Ultra, single)

Setup: force evaluations only (Verlet 1e-9 ps, no constraints), 3 s windows, loads 3.7 to 5.8. Per-kernel values are each kernel's own start-to-end span in us per step (profiler's convention). The step is the mean of the unprofiled windows A and C, host clock. Speedups and drops are against base (71a602b43 plus the profiler hooks). 1 atomic and plain give wrong forces and exist only to price the atomics.

| test | row | base | 1 atomic | plain | words | 1 atomic | plain | words |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| apoa1rf | computeBondedForces | 176.0 | 80.9 | 29.4 | 323.6 | 54% less | 83% less | 84% more |
| apoa1rf | computeNonbonded | 513.0 | 286.6 | 313.1 | 490.4 | 44% less | 39% less | 4% less |
| apoa1rf | foldForceWords | | | | 21.4 | | | |
| apoa1rf | step | 818.5 | 498.8 | 469.9 | 740.6 | 1.641x | 1.742x | 1.105x |
| rf | computeBondedForces | 27.4 | 16.8 | 17.3 | 28.6 | 39% less | 37% less | 5% more |
| rf | computeNonbonded | 147.9 | 79.1 | 89.5 | 124.1 | 47% less | 39% less | 16% less |
| rf | foldForceWords | | | | 9.1 | | | |
| rf | step | 289.6 | 294.8 | 271.4 | 271.6 | 0.982x | 1.067x | 1.067x |
| apoa1pme | computeBondedForces | 253.4 | 114.8 | 38.6 | 354.1 | 55% less | 85% less | 40% more |
| apoa1pme | computeNonbonded | 411.5 | 266.9 | 294.1 | 575.8 | 35% less | 29% less | 40% more |
| apoa1pme | foldForceWords | | | | 22.1 | | | |
| apoa1pme | step | 1242.1 | 965.8 | 906.9 | 1234.8 | 1.286x | 1.370x | 1.006x |
| cellulose | computeBondedForces | 955.8 | 458.4 | 129.9 | 1520.4 | 52% less | 86% less | 59% more |
| cellulose | computeNonbonded | 1683.5 | 1361.0 | 1455.6 | 2475.1 | 19% less | 14% less | 47% more |
| cellulose | foldForceWords | | | | 70.9 | | | |
| cellulose | step | 4475.6 | 3671.2 | 3417.8 | 4531.9 | 1.219x | 1.309x | 0.988x |
| gbsa | computeBondedForces | 26.0 | | | 40.3 | | | 55% more |
| gbsa | computeNonbonded | 53.8 | | | 59.3 | | | 10% more |
| gbsa | foldForceWords | | | | 5.6 | | | |
| gbsa | step | 245.4 | | | 250.5 | | | 0.980x |
| pme | computeBondedForces | 41.5 | | | 80.4 | | | 94% more |
| pme | computeNonbonded | 117.6 | | | 129.2 | | | 10% more |
| pme | foldForceWords | | | | 9.1 | | | |
| pme | step | 410.9 | | | 418.8 | | | 0.981x |

Against the lead's thresholds:
- Chunked bonded is a go. computeBondedForces falls 83% (apoa1rf) and 86% (cellulose) under plain RMW, against a 50% bar. The bonded kernel's time is mostly atomics.
- x-resident is a go. computeNonbonded falls 44% under 1 atomic on apoa1rf, against a 25% bar. It falls 35% on apoa1pme, 47% on rf and 19% on cellulose.
- The whole step with a single atomic is 1.64x on apoa1rf, 1.29x on apoa1pme and 1.22x on cellulose. Atomics are about a fifth to two fifths of the step.

The atomic microbenchmark (ub-2.txt, 288k tiles, median of 5, no ALU work) gives emulation 1,490 us, one returning 32-bit atomic (k_ret) 1,025 us, words 1,523 us, one non-returning atomic 876 us and plain 220 us. With 400 FMAs per tile: emulation 2,637, k_ret 2,348 and words 2,816. Per add, words costs as much as the emulation. Its placement ALU and its spread over five word planes eat all of the returning atomic's saving.

Where the words gain comes from: overlap, not fewer atomic ops. The words arm's spans exceed its overlap-attributed times: bonded is 323.6 us span against 173.8 attributed on apoa1rf, and base is 176.0 against 142.3. One step's dispatch timeline on apoa1rf shows it:
- In base, computeBondedForces runs from 52 to 226 us, and computeNonbonded starts at 226.3, after it.
- In words, computeNonbonded starts at 111.4 us, right after copyInteractionCounts, and computeBondedForces runs from 142.5 to 648.7 us alongside it.

The MetalQueue encoder is serial, but the driver lets dispatches overlap unless they share a tracked writable buffer. Bonded and nonbonded both write the long force buffer, so Metal serializes them, although atomic adds commute. Words moves nonbonded's writes to another buffer, which removes that dependency. Encoder busy time drops by 87 us on apoa1rf and 86 us on apoa1pme. The fold then gives back 21 to 71 us, and on gbsa and pme the fold (5.6 and 9.1 us) is the whole loss. The same overlap without the words or the fold would come from not tracking the long force buffer as a hazard between force kernels, with an explicit fence before its readers. I'm raising that with the lead as a new candidate.

gate --quick on 4be61f9b6: PASS. Bonded screens requeued (pids 34122, 34354) now that 1a says go.

### 23:30Z overlap candidate routed to dispatch; bonded census queued

The bonded and nonbonded overlap is the design's orchestration Design 3 (accumulate hazard class on a concurrent encoder), which the dispatch lane owns, so I sent the lead the data point instead of starting it. Apple's MTLComputeCommandEncoder.h says memoryBarrier "on a serial encoder is allowed, but ignored", so an explicit fence needs the concurrent encoder, as Design 3 says. The profiler patch gives every dispatch its own encoder only while GPUPROF_ON is set, so windows A and C run with the normal serial encoder. Yet A and C show the same 78 us words gain on apoa1rf. Either the serial encoder already overlaps dispatches that share no tracked writable buffer, or words' adds are cheaper in the real kernel than in the microbenchmark. The words nonbonded span (490 us, while sharing the GPU with bonded) against base's 513 hints that both are true.

For the lead's census rule (bonded moves 20% or more but the step gains under 3%), bbp.sh builds profiler-hooked plugins in src-bp and build-bp, with no tests and no install: plugins-prof-bonded (d8ab45b2b) and plugins-prof-b0 (71a602b43). Every file the patch leaves alone is checked against git. It waits for /tmp/openmm-window. Census 1b (p1a/run1b.sh, counters, force evaluations only, the same method as 1a) is queued as its own lease, pid 87308. It covers apoa1rf, apoa1pme, cellulose, pme, gbsa and rf, and refuses to run unless both plugins match bbp.sh's md5s.
bbp.sh done at 23:33Z: plugins-prof-bonded md5 92a20a60 (bondedPad present, profiler hooks present), plugins-prof-b0 md5 35f2507f (no bondedPad, hooks present). The untouched files matched git in both arms.

### 23:55Z untracked force buffer: inventory, plan, hazard probe queued

Lead item 1. The inventory below is for 71a602b43 (p0), where computeNonbonded adds straight into the long buffer and there is no fold. Paths are under platforms/.

Benchmark path, in step order:
- common/src/ComputeContext.cpp:224 clearAutoclearBuffers, from metal/src/MetalKernels.cpp:61. Overwrites the long buffer with zeros in the same dispatch as energyBuffer (entries 0 and 1 of the autoclear list, metal/src/MetalContext.cpp:359-360). Command buffer 1.
- Neighbor list build, then copyInteractionCounts and downloadCountEvent->enqueue() (metal/src/MetalNonbondedUtilities.cpp:424), which commits command buffer 1. None touch the long buffer.
- PME only: gridInterpolateForce, common/src/CommonCalcNonbondedForce.cpp:808 (arg) and :1033 (dispatch), kernels/pme.cc:346-354. Plain +=, because Metal's PME stream is off by default (metal/src/MetalPlatform.cpp:137). Command buffer 2, before bonded.
- gbsa only: computeGBSAForce1, common/src/CommonKernels.cpp:2054 (arg) and :2102. ATOMIC_ADD. It also does a plain += on energyBuffer. Command buffer 2, before bonded.
- computeBondedForces, common/src/BondedUtilities.cpp:175, dispatched at :207 from MetalKernels.cpp:75. ATOMIC_ADD. It also writes energyBuffer unconditionally (:123).
- computeNonbonded, metal/src/MetalNonbondedUtilities.cpp:316. ATOMIC_ADD. The no-energy variant binds energyBuffer but never writes it. Then commit of command buffer 2 and a CPU wait on the count event from command buffer 1.
- distributeForcesFromVirtualSites, metal/src/MetalIntegrationUtilities.cpp:157. Read, then ATOMIC_ADD or plain +=. Returns early on the six systems (no virtual sites).
- integrateLangevinMiddlePart1, common/src/CommonKernels.cpp:3149 (arg) and :3190. Read. Command buffer 3. No constraint kernel reads the buffer.

Off the timed path:
- Host download: getForces, CommonKernels.cpp:289.
- Blit copies: saveCoordinates and restoreCoordinates, CommonKernels.cpp:4327 and :4355 (barostat).
- Minimizer: CommonMinimizeKernel.cpp:216 (read) and :225 (ATOMIC_ADD).
- timeShiftVelocities: IntegrationUtilities.cpp:957 and :997 (read).
- Other integrators: Verlet, Brownian, VariableVerlet, VariableLangevin and DPD read it (CommonKernels.cpp:3078, 3233, 3317, 3334, 3425, 3449, 3604). CustomIntegrator reads it and blit-copies it (CommonIntegrateCustomStepKernel.cpp:459, 550, 670, 685). NoseHoover and QTB read it (CommonIntegrateNoseHooverStepKernel.cpp:154, CommonIntegrateQTBStepKernel.cpp:125).
- Plain += writers, all in force execute() before bonded:
  - Ewald: CommonCalcNonbondedForce.cpp:762
  - LJPME interpolate: :869
  - CustomCV addForces: CommonKernels.cpp:2669
  - RMSD: :3780
  - OrientationRestraint: :4076
  - ATM hybridForce: :4555
  - CustomGB per-particle: CommonCalcCustomGBForceKernel.cpp:953, and :971 reads then overwrites
  - ConstantPotential: CommonCalcConstantPotentialForce.cpp:1255 and :1500
- Plain += writers in post computations, after nonbonded:
  - CPU PME: CommonCalcNonbondedForce.cpp:128
  - CustomCPPForce: CommonKernels.cpp:4706
  - PythonForce: :4859 and :4867
- ATOMIC_ADD writers in execute():
  - CustomCentroidBond: CommonKernels.cpp:1898
  - GayBerne: :2349 and :2373
  - LCPO: :2947
  - RG: :3970
  - CustomManyParticle: CommonCalcCustomManyParticleForceKernel.cpp:401
  - CustomGB N2: CommonCalcCustomGBForceKernel.cpp:914
  - CustomHbond: CommonCalcCustomHbondForceKernel.cpp:463
  - CustomNonbonded interaction groups: CommonCalcCustomNonbondedForceKernel.cpp:673
- Plugins:
  - AMOEBA: AmoebaCommonKernels.cpp. Atomics at 506, 678, 1928, 1941, 1953, 2300, 2635 and 3090. Plain += or -= at 654, 811, 824, 2775, 2794 and 2883. Vdw blit-copies the buffer out and back around its own nonbonded utilities at 2185 and 2191.
  - Drude reads it (CommonDrudeKernels.cpp:274, 429 and 444) and downloads it (:510).
  - RPMD reads it (CommonRpmdKernels.cpp:198).

The only hazards that matter are the plain writers and the readers. Atomic adds commute with each other.

Plan, pending the probe. Untracking the whole buffer would need a fence at every pass and command-buffer boundary with a force user on both sides. That is every row above. The smaller shape keeps the long buffer tracked for everyone except bonded:
- computeBondedForces binds an untracked alias. The alias is a second MTLBuffer made with newBufferWithBytesNoCopy over the same pages. The feature turns off when the contents aren't page aligned or allocatedSize can't hold the page-rounded length.
- Bonded runs in its own pass. The pass before it updates fence Fin, which covers PME's plain +=. Bonded waits on Fin and updates Fout.
- Nonbonded gets its own pass, which does not wait on Fout, so bonded and nonbonded can overlap.
- The next pass that touches the buffer waits on Fout. On the benchmark path that is the first pass of command buffer 3, because command buffer 2 commits right after nonbonded.
- clear before bonded, and bonded before the next clear, are ordered already by energyBuffer. It is tracked, written by the clear, and written by bonded in every call.

Per MTLComputeCommandEncoder.h:246-259, drivers may delay fence updates to the end of an encoder and wait at its start. So fences only work at pass granularity, which needs dispatch's splitPass (c515f3b34, not on 71a602b43) plus a fence hook on pass boundaries.

Fallback that needs no queue API: a tracked alias with two 1-thread dispatches around bonded. A fork binds orig and alias, then bonded binds only the alias, then a join binds both. This works only if the serial encoder already overlaps dispatches that share no tracked buffer object.

Hazard probe hz ($L/hz.mm, pid 33678, timing lease). It uses two 1-simdgroup dispatches in one command buffer. A producer spins and then writes x. A consumer reads x first and then spins. Overlap shows as about 1x the spin time, and a missed order shows as a stale read. The probe measures:
- whether a serial encoder overlaps dispatches that share no tracked buffer
- whether an unwritten `device` argument or a shared `const` one serializes them
- whether a tracked alias object and an untracked one are ordered against the original
- untracked buffers in one encoder, in passes with and without a fence, and across command buffers with a fence
- the cost of a 1-thread dispatch, a pass split and a pass with a fence

The design waits for its result.

### 00:10Z x-resident design note (lead item 4, no GPU)

Nonbonded had already built x-resident as 1eb207c25 on ultra/nonbonded-xres at 23:48Z: +31 -10 in nonbonded.metal, on top of 6d72c3ae9. gate --quick passed and the screen is queued. So this note is the design written against that commit.

What stays resident. Nothing goes in threadgroup memory. A neighbor-list tile's x block belongs to one simdgroup, so the x-side force stays in that simdgroup's registers (3 per lane) until the next tile has a different x. That is exactly what 1eb207c25 does. Sharing it across the two simdgroups of a 64-thread group would need a threadgroup barrier per flush, and the two simdgroups rarely hold the same x. The j side can't stay resident, because each tile brings 32 new j atoms.

Atomics per lane per neighbor-list tile:
- Before: 6 emulated 64-bit adds, 3 on x and 3 on j. That is about 9 to 12 32-bit atomic ops, since the high word is written whenever the value is negative or carries.
- After: 3 on j plus 3 x-adds per run of same-x tiles.

findBlocksWithInteractions stores a block row in batches of (BUFFER_SIZE-32)/32 = 7 tiles, plus one partial batch at the row's end. Each batch lands at an atomicAdd slot (findInteractingBlocks.metal:587, :614), so runs average about 6 to 7 tiles.

Estimates, where W is the number of warps (4,800 on the M3 Ultra, 800 on the M2) and T is tiles per warp:

| test | M3 Ultra T | M3 Ultra adds per tile | M2 T | M2 adds per tile |
|---|---:|---:|---:|---:|
| apoa1rf, apoa1pme (about 78k tiles) | about 16 | about 3.6 (-39%) | about 98 | about 3.5 (-42%) |
| cellulose | about 70 | about 3.5 (-42%) | | about 3.4 |
| rf, pme | about 4 | about 4.2 (-30%) | | about 3.6 |
| gbsa | under 1 | unchanged | | |

These are estimates. The census row for computeNonbonded settles them.

Correctness problem in 1eb207c25: it breaks DeterministicForces. It sums the x force of several tiles in float and converts once at the flush. Which tiles share a flush depends on where each batch landed, and that comes from the atomicAdd slot allocation in findBlocksWithInteractions, which changes from run to run. So the float sums, and the forces' last bits, change between runs of the same state. Today each tile's force is converted on its own, and fixed-point sums are exact, so the list order doesn't matter.

Proposed fix, about 6 lines:
- Keep the x-side accumulator as 3 mm_long in registers.
- Each tile adds realToFixedPoint(force) into them, then zeroes the float force.
- The flush does one atomicAdd of the long sum.

Integer adds are exact mod 2^64, so the result is bitwise identical to base, not only within rounding. The gate can then check equality against the base build. The cost per tile is 3 conversions, which base already pays, plus 3 register 64-bit adds. The alternative, disabling x-resident when deterministicForces is set, keeps the nondeterminism in the default mode. The lead's check (forces x5 bitwise under DeterministicForces) would fail it, and tests that compare two evaluations of the same state could flake.

Conflicts:
- Words (4be61f9b6, on hold) edits the same six atomicAdd sites, at p0 nonbonded.metal:221-223, 229-231, 435-437 and 440-442. x-resident changes when the x add fires, and words changes how the add is done. They compose. If words comes back, it rebases onto x-resident with the long accumulator. The flush then adds a long, so words would need a 64-bit entry point, which it lacks today.
- The untracked force buffer: no kernel conflict, because it only changes the host binding and pass order for bonded. The gains are sub-additive, though. x-resident shortens computeNonbonded, which leaves less time for bonded to hide under. Screen x-resident first, then untracked on top.
- Chunked bonded (d8ab45b2b): no conflict. It lives in a different kernel and file.
- HIPPO: no conflict. Its own kernel source never compiles nonbonded.metal. It shares the argument layout, and the kernel signature is unchanged.

00:15Z cleanup: I deleted plugins-base, -defer, -lo, -plain, -twonr and -words (CLT era) and plugins-prof-lo and -prof-plain (1a done). No queued job reads them. I kept plugins-prof and -prof-words in case words is revisited.

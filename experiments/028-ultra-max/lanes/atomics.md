# Lane: atomics (force accumulation)

Worktree /Users/amir/code/mini/ultra-atomics, branch ultra/atomics off 6df2b8bcb. Studio scratch /tmp/openmm-metal-bench/ultra-atomics. Started 2026-09-24 19:23Z, hard cap 23:53Z.

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

# Lane: PME (reciprocal space, LJPME)

Worktree /Users/amir/code/mini/ultra-pme, branch ultra/pme off 6df2b8bcb. Studio scratch /tmp/openmm-metal-bench/ultra-pme (src, build, prefix, bench). Started 2026-09-24 19:25Z. No freeze since 21:58Z: the program runs continuously in three loops (RULES.md).

## How PME runs at 6df2b8bcb

- Metal uses the common PME path (platforms/common/src/kernels/pme.cc, CommonCalcNonbondedForce.cpp). Correction (20:30Z): the separate PME queue is off by default, because MetalPlatform.cpp:137 defaults MetalDisablePmeStream to true, so PME runs in series with nonbonded on the main queue. That matches the host-clock split below, where recip plus direct add up to all.
- Kernels per step: findAtomGridIndex and a sort of pmeAtomGridIndex (every other step above 15000 atoms, twice every step for LJPME), gridSpreadCharge, finishSpreadCharge (fixed point only), VkFFT forward (R2C, 3 axis dispatches), reciprocalConvolution (plus gridEvaluateEnergy when energy is asked for), VkFFT inverse, gridInterpolateForce with three emulated 64-bit atomics per atom.
- MetalContext hardcodes supportsHardwareFloatGlobalAtomicAdd = false, so charge spreading takes the fixed-point path: every grid add is an emulated 64-bit atomic (two 32-bit atomics when the value is negative or carries), then finishSpreadCharge converts the grid. PME is the only reader of that flag.
- The FFT is VkFFT 1.2.33 with the Metal backend, useLUT=1, maxThreadsNum capped at 256.
- Grids at ewaldErrorTolerance 5e-4: pme 56^3, apoa1pme 98^3.

## Tools (Studio, /tmp/openmm-metal-bench/ultra-pme)

- env.sh ROOT script.py: runs python against ROOT/build/python/build/lib* and ROOT/prefix/lib; refuses unless nice is 0.
- leased.sh "what" cmd: waits for /tmp/openmm-lease, writes the owner line, logs the 1-minute load, releases on exit.
- pmeprof.py: reciprocal in force group 1, the rest in 0, an empty force in 2; times getState(forces) per group on the host clock.
- bprops.py: benchmark.py with extra platform properties from EXTRA_PROPS.
- ab.py ROUNDS SECONDS TESTS PRECS name=ROOT[:Prop=v;...]: interleaved benchmark.py A/B, order reversed every other round, median per config.

## Log

### 22:25 host-clock split, base build (load 8, other lanes building)

getState(forces) per group, ms, after subtracting nothing (empty group = fixed cost):

| test | empty | recip | direct | all |
|---|---|---|---|---|
| pme single | 0.26 | 0.50 | 0.56 | 0.77 |
| apoa1pme single | 1.05 | 2.02 | 2.18 | 3.26 |
| apoa1pme mixed | 1.00 | 2.09 | 2.24 | 3.28 |

On apoa1pme, recip minus empty is about 1.0 ms and direct minus empty about 1.1 ms, and all minus empty is 2.2 ms: the PME queue buys almost no overlap, and PME is close to half of the force evaluation.

### 19:34Z native float atomics for spreading (same-build screen)

Change: supportsHardwareFloatGlobalAtomicAdd true in MetalContext (1 line). Screened in one build with DeterministicForces=true (fixed point, as base) against false (float), 2 rounds of 15 s, load 3 to 16 (other lanes building).

| test (single) | fixed ns/day | float ns/day | ratio |
|---|---|---|---|
| pme | 540.0 | 596.1 | 1.104 |
| apoa1pme | 194.2 | 225.2 | 1.159 |
| apoa1ljpme | 143.0 | 167.6 | 1.172 |

Committed as c5f2cb6ed. Candidate build in ultra-pme/cand (infra build.sh) for the gate and the A/B against ultra-base.

Lab build (ultra-pme/build, not committed) carries env knobs: PME_LAB_NOSORT, PME_LAB_LUT, PME_LAB_COALESCED, PME_LAB_AIM, PME_LAB_REGBOOST, PME_LAB_BANKS.

### 19:50Z lab knob screen (float build, 2 x 15 s, load 3 to 18)

| knob | apoa1pme single | pme single |
|---|---|---|
| no PME atom sort | 1.022 | 1.034 |
| VkFFT useLUT -1 (sincos) | 0.996 | 0.998 |
| VkFFT coalescedMemory 32 | 1.001 | 1.004 |
| VkFFT coalescedMemory 128 | 0.999 | 1.000 |
| VkFFT aimThreads 256 | 1.000 | 1.001 |

VkFFT's tuning knobs are flat: dead end. Skipping the sort (findAtomGridIndex plus five sort kernels, every other step; twice every step for LJPME) wins: reorderAtoms already keeps atoms spatially ordered.

Committed 57ba03190 "Skip the PME atom sort on Metal": commonInitialize gets sortPmeAtoms (default true, so OpenCL and the rest keep sorting); Metal passes false and uploads an identity pmeAtomGridIndex once. +21/-10 lines. Built in ultra-pme/cand2.

Gate of cand (c5f2cb6ed) queued 20:16Z. The lease is starved: ab.sh re-takes it between tests while waiters poll every 10 s; told infra.

### Launch sizes

MetalContext::executeKernel caps a launch at numThreadBlocks (12 per core x 60 = 720) blocks of 64, so 46080 threads. gridSpreadCharge is launched with execute(numAtoms) and loops over numAtoms*5 work items, so on apoa1pme each thread does 10 of them; gridInterpolateForce does 2 atoms per thread, with 125 dependent-ish grid loads per atom. Next lab screen: a gather kernel with 5 SIMD lanes per atom (one per z offset, simd_shuffle_down reduction, Metal-only under USE_METAL), and larger spread launches (PME_LAB_SPREAD_MUL, PME_LAB_BLOCK).

### 20:20Z to 20:35Z: device keying, toolchain and profiler numbers

- The profiler's counters run of 6df2b8bcb (fixed-point spread) on apoa1pme puts gridSpreadCharge at 429 us of a 1707 us step. The FFTs take 58 us each way, gridInterpolateForce 43 us, reciprocalConvolution 15 us and finishSpreadCharge 18 us (median). After float atomics, spread is still the biggest PME kernel. Gather and FFT are worth less than 4% each.
- Float atomics are now keyed on MTL::GPUFamilyApple9. Lab 011 measured the M2's fixed-point spread plus finish at 0.805 ms against 0.830 ms for float. I rewrote the commit as 71a602b43 (+4 lines) and replayed nosort on top as 17929e631 (+21/-10). Both still need an M2 check.
- Built cand2 (17929e631) with the Xcode-beta toolchain. Its gate started 20:35Z. ultra-base is being rebuilt, so the A/B waits for its READY.
- Rule break, reported and fixed by the lead: my lab build ran PythonInstall with the env's python, which wrote openmm into the shared env. The lab tree now builds with build.sh, into its own venv.
- The pgrep build guard in RULES.md exits 2 on macOS, because `clang++` is not a valid regex. env.sh waits on `pgrep -x 'clang|clang\+\+|ninja|cc1plus'` and logs the load and the top processes before every run.

Lab kernels queued (lab tree, env knobs, not for commit):
- PME_LAB_TILED: gridSpreadChargeTiled. Each threadgroup of 256 spreads 256 consecutive atoms into a threadgroup tile of up to 7168 points. The tile covers the chunk's bounding box plus the stencil, unwrapped across the periodic boundary. Each touched point is then flushed with one device atomic, and chunks that don't fit go straight to the grid. Before MSL 4.1 the tile adds through a CAS loop. Under MSL 4.1 it uses threadgroup atomic_float, which compiles with Xcode-beta's `xcrun metal -std=metal4.1` but not at 3.2 or 4.0.
- PME_LAB_MSL41 compiles every program as MSL 4.1.
- PME_LAB_PLAIN and PME_LAB_NOWRITE are timing-only spread variants: a non-atomic add, and no write at all. They split the spread's time into atomics, memory and ALU.
- PMEPROF_GRID with fftsizes.sh sweeps the FFT alone over grid sizes: 96 to 112 for apoa1pme, 56 to 64 for pme.

### 20:45Z M2 screen: 17929e631 against 6df2b8bcb

M2 (Apple8, so the spread stays fixed point and only the sort skip differs), benchmark.py single, 2 rounds of 15 s interleaved, host clock, load 1.7 to 5.7, mini lease held.

| test | base ns/day | cand ns/day | ratio |
|---|---|---|---|
| pme | 204.5 | 206.5 | 1.010 |
| apoa1pme | 54.35 | 54.11 | 0.996 |
| apoa1ljpme | 40.25 | 41.57 | 1.033 |

No regression on the M2; the -0.4% on apoa1pme is inside screen noise and the 1% limit. Forces against Reference on the M2 (the gate's forces.py, base's table as the baseline): all 12 rows ok, rel|dF| identical to base to 4 digits (pme 2.048e-05, apoa1pme 7.747e-05, apoa1ljpme 7.747e-05). The M2 check of 71a602b43 plus 17929e631 passes; on the M2 71a602b43 changes nothing, since Apple8 keeps fixed point.

### 21:03Z M2 lab screen: tiled spread (dead on the M2)

Lab tree on the M2 (the working tree at 17929e631 plus the LAB knobs, plus PME_LAB_FLOAT to force float atomics on Apple8). Reciprocal forces against the default fixed-point spread, rel|dF|:

| test | float | tiled (CAS) | tiled41 (MSL 4.1 atomic_float) |
|---|---|---|---|
| pme | 1.18e-06 | 1.91e-06 | 1.91e-06 |
| apoa1pme | 1.42e-06 | 1.90e-06 | 1.94e-06 |
| apoa1ljpme | 1.39e-06 | 1.90e-06 | 1.96e-06 |

The tiled kernel is correct (roundoff level) under both MSL versions, including the LJPME dispersion grid. MSL 4.1 compiles and runs on the M2 under macOS 27.2.

Speed, 2 x 15 s interleaved, single, ns/day and ratio to fixed point:

| test | fixed | float | tiled | tiled41 |
|---|---|---|---|---|
| pme | 210.5 | 201.7 (0.958) | 167.9 (0.798) | 165.1 (0.784) |
| apoa1pme | 54.16 | 52.56 (0.970) | 43.40 (0.801) | 43.44 (0.802) |
| apoa1ljpme | 41.60 | 38.91 (0.935) | 33.22 (0.799) | 33.24 (0.799) |

On the M2 the tiled spread costs about 0.8 ms more per apoa1pme step than fixed point, so it runs at roughly half the speed of the device-atomic spread. Native threadgroup atomic_float is no faster than the CAS loop, which suggests the compiler emits a CAS for it on Apple8, or that threadgroup atomic throughput is the limit either way. The tile uses 28 KB, so each core holds one 256-thread group. The float row confirms the Apple9 keying: device float atomics lose 3 to 7% to fixed point on the M2.

Grid size change for the FFT is off the table: Metal would then use a different grid than Reference, and the gate compares against Reference, so the discretization difference alone would fail it.

The Studio screen (ticket 41058) is trimmed to base, PME stream, tiled41 and a 256-thread spread launch with one work item per thread (PME_LAB_BLOCK=256, PME_LAB_SPREAD_MUL=5).

### 21:10Z lab tree rebuilt for the Studio screen

One guess for the M2 slowdown is latency: the tiled kernel gives each thread a whole atom (125 dependent-return threadgroup atomics), and the 28 KB tile allows one 256-thread group per core, against about 768 threads per core for the default spread. New LAB knobs:
- PME_LAB_TILE_ITEMS: the spreading pass gives each (atom, z offset) pair its own thread, as gridSpreadCharge does.
- PME_LAB_TILE_BLOCK: the tiled kernel's group size, capped at the pipeline's maxTotalThreadsPerThreadgroup.
- PME_LAB_TILE_POINTS: the tile size.
- PME_LAB_FLOAT: forces float atomics on Apple8, for M2 experiments only.

The queued Studio screen (ticket 41058, spreadvar.sh) now runs ultra-base, lab (17929e631 behavior), stream, tiled41, ti1024 (tiled41 plus TILE_ITEMS and 1024-thread groups) and b256m5, on apoa1pme, pme and apoa1ljpme. The lab tree was rebuilt at 21:08Z (build.sh), and its sources match labhash.txt.

### 21:38Z M2 lab screen: more threads for the tiled spread

M2, lab tree rebuilt at 21:09Z (hashes match labhash.txt), 2 x 15 s interleaved, single, ns/day and ratio to fixed point. All tiled rows force float atomics and MSL 4.1.

| test | fixed | float | tiled41 (256 threads, atom each) | ti256 (256 threads, atom and z each) | ti1024 (1024 threads, atom and z each) |
|---|---|---|---|---|---|
| pme | 205.8 | 196.5 (0.955) | 162.5 (0.790) | 170.1 (0.827) | 178.4 (0.867) |
| apoa1pme | 54.20 | 52.62 (0.971) | 43.28 (0.798) | 45.51 (0.840) | 48.00 (0.886) |

More threads per tile recover about half the loss, so latency is part of the cost, but the best tiled kernel still trails the default float spread by 9% and fixed point by 11 to 13% on the M2. On Apple8, threadgroup atomics are slower than device atomics for this pattern. The Ultra (Apple9) screen is still queued.

### 21:42Z to 22:00Z M3 Ultra screen: stream, tiled spread, launch shape (all dead)

One hold (ticket 41058), lab tree built 21:08Z with sources matching labhash.txt. Single precision, 2 x 15 s interleaved, host clock, 1-minute load 4 to 20 (highest during the apoa1ljpme rounds). ns/day and ratio to ultra-base:

| test | ultra-base | lab (17929e631) | stream | tiled41 | ti1024 | b256m5 |
|---|---|---|---|---|---|---|
| apoa1pme | 194.2 | 230.9 (1.189) | 198.9 (1.024) | 178.8 (0.921) | 230.1 (1.185) | 230.5 (1.187) |
| pme | 541.7 | 623.0 (1.150) | 410.8 (0.758) | 516.5 (0.954) | 621.5 (1.147) | 621.6 (1.148) |
| apoa1ljpme | 145.6 | 199.8 (1.372) | 181.4 (1.246) | 158.7 (1.090) | 194.1 (1.333) | 201.1 (1.382) |

Against the lab tree:
- PME stream (DisablePmeStream=false): 0.861, 0.659 and 0.908. Dead on the M3 Ultra. It is dead on the M2 too: 0.884 on pme, 0.959 on apoa1pme and 0.968 on apoa1ljpme (m2var2.log, 2 x 15 s, load 2 to 3). I did not profile why; the stream path adds command-buffer commits per step and switches the gather to 64-bit force atomics, and either could cost more than the overlap saves.
- Tiled spread, one atom per thread (tiled41): 0.774, 0.829 and 0.794. Dead.
- Tiled spread, one (atom, z) pair per thread in 1024-thread groups (ti1024): 0.997, 0.998 and 0.971. It ties at best, so threadgroup atomics on Apple9 cost about what the device atomics they replace cost. Dead, and it would have needed MSL 4.1 or a CAS.
- Default spread in 256-thread groups, one work item per thread (b256m5): 0.998, 0.998 and 1.007. Flat.

pmeprof on apoa1pme, as the extra time of the reciprocal group over the direct group alone (all minus direct, two repeats, getState sync included):

| build | all minus direct |
|---|---|
| ultra-base | 0.66, 0.75 ms |
| lab (float, no sort) | 0.43, 0.46 ms |
| lab, plain non-atomic spread (wrong results, timing only) | 0.20, 0.23 ms |
| lab, spread with no writes at all (timing only) | 0.19, 0.21 ms |
| lab, ti1024 | 0.41, 0.38 ms |

On apoa1ljpme, all minus direct went from 1.28 ms (ultra-base) to 0.61 and 0.53 ms (lab).

The float atomics are about half of the remaining reciprocal cost: a plain read-modify-write costs about what no write at all costs. The tile experiments show that threadgroup atomics don't avoid that cost on either GPU. Removing atomics altogether would take a race-free partition (eight parity passes over 5-cell blocks, with atoms binned per block every step). That brings back a binning pass like the sort that 17929e631 removed, and the passes are serial within each block, with about 1000 blocks per parity class on apoa1pme. I don't expect it to pay, so I'm not building it tonight.

### 22:10Z Candidate status and the native roadmap

- 71a602b43 and 17929e631 are pushed to the mini remote (branch ultra/pme). The full gate of the cand2 tree (17929e631, file hashes checked against git) is queued as ticket cand2-50466, behind the ultra-base ticket that I take to be infra's forces.txt regen. Screens of cand2 against ultra-base are queued too: amber20-dhfr and amber20-cellulose single, amber20-stmv single, and pme, apoa1pme and apoa1ljpme mixed. Only NonbondedForce PME on Metal reads the float-atomics flag (AMOEBA has no Metal kernels yet), so gbsa, rf and apoa1rf run the same code as ultra-base and aren't screened.
- Int-tile spread (roadmap item 8): killed by its own rule without a build. tiled41 is below 0.9x of float on the Ultra (0.774, 0.829, 0.794). ti1024 only ties (0.997, 0.998, 0.971), so the spread's device atomics are not where threadgroup atomics win on Apple9.
- PME as its own tracked pass (roadmap item 2): the probe is built. With PME_LAB_SPLIT set, the encoder ends before findBlockBounds (so the neighbor-list build is its own pass, apart from integration and the clears that write posq and the force buffers), and before and after MetalCalcNonbondedForceKernel::execute, so the reciprocal chain is its own pass. PME_LAB_SPLIT_BONDED also ends the encoder between bonded and nonbonded. PME_LAB_SKIP=interp now skips the dispersion interpolation too. The probe keeps interpolation's += into the force buffers, so with interpolation on, the split lets the chain overlap only the list build (the next pass writes the same force buffers). With interpolation skipped, it shows what the full design (pmeForce array plus a fold) could reach.
  - M3 Ultra: splitvar.sh queued as one hold (forces of the split arms against Reference, then 6 arms on pme, apoa1pme and apoa1ljpme, 2 x 15 s).
  - M2: on Apple8 every force sum is fixed point, so the split arms must match the serial lab tree bitwise, on a fresh Context and after 50 Verlet steps (splitcheck.py), then a 2 x 15 s screen (m2split.sh).

### 22:10Z M2: split-pass probe (m2split1.log)

Lab tree (17929e631 plus knobs) on the M2, single precision, fixed-point spread (Apple8).
- Bitwise check (splitcheck.py: all-group forces on a fresh Context, then forces, positions and energy after 50 Verlet steps of 1 fs). split and splitb against the serial lab tree: forces and positions have max|diff| 0 on pme, apoa1pme and apoa1ljpme, at step 0 and at step 50. Potential energy after 50 steps differs by 0.0156 and 0.0312 kJ/mol on pme, 0.0625 on apoa1pme and 0 on apoa1ljpme, which is 1 or 2 float ulps at those magnitudes. My guess is that the serial tree varies the same way run to run: nonbonded tiles are appended with atomics and energy sums in float. m2pmef.sh checks that guess by running the serial tree twice more.
- Screen, 2 x 15 s, load 1.6 to 2.5, ns/day as the mean of the two rounds, ratio to lab:

| test | lab | split | skipi | splitskipi |
|---|---|---|---|---|
| pme | 204.3 | 204.4 (1.000) | 212.6 (1.041) | 213.0 (1.043) |
| apoa1pme | 54.14 | 54.15 (1.000) | 56.75 (1.048) | 56.71 (1.048) |

On the M2 the split costs nothing measurable and gains nothing. splitskipi matches skipi, so the chain doesn't overlap anything on the M2 even with interpolation out of the way, as the design predicted for 10 cores that computeNonbonded already fills. Interpolation itself costs about 4 to 5% of the M2's step.

### 22:15Z M2: pmeForce fold (m2pmef1.log)

PME_LAB_PMEFORCE: gridInterpolateForce stores each atom's reciprocal force as a real4 in pmeForce (a second array for LJPME dispersion) instead of += into the fixed-point force buffers. A post computation folds them in with pme.cc's existing addForces kernel after nonbonded, so the reciprocal chain no longer writes anything bonded or nonbonded touch. About 40 lab lines.
- Energy noise: the serial lab tree run three times gives 50-step energies that differ by 0 and 0.0156 kJ/mol on pme, so the ulp-level energy differences in the split arms are the serial tree's own run-to-run noise.
- Bitwise: pmef0 (fold, no split) and pmefb (fold, split, bonded in its own pass) against the serial lab tree give max|diff| 0 for forces at step 0 and step 50 and for positions at step 50, on pme, apoa1pme and apoa1ljpme. The fold adds the same fixed-point integers in a different order, and integer adds commute.
- Screen, 2 x 15 s: pmef (split plus fold) 0.989 on pme and 0.995 on apoa1pme; pmefb 0.989 and 0.995. On the M2 the fold's extra dispatch and pass boundaries cost about 1% on pme, and there is nothing to hide the chain behind. So whatever ships must stay off on the M2.

### 22:35Z Can the PME chain overlap other passes? The profiler's counters records say yes

The profiler's counters mode gives every dispatch its own encoder with start and end timestamps, so its records show what Metal's hazard tracking lets run concurrently. pmeoverlap.py reads ultra-base's records (p1/, fixed-point spread, sorted atoms) and takes per step the list build (findBlockBounds to copyInteractionCounts, in the first command buffer) and the PME chain (findAtomGridIndex or gridSpreadCharge to gridInterpolateForce, in the second). Medians in us:

| test | steps | list build union | PME chain union | list and PME overlap | PME start minus list end | PME overlap with bonded and nonbonded |
|---|---|---|---|---|---|---|
| pme | 5879 | 316.7 | 266.6 | 26.4 | -49.0 | 0 |
| apoa1pme | 2169 | 554.0 | 841.5 | 352.9 | -384.3 | 0 |
| apoa1ljpme | 1607 | 535.3 | 983.0 | 333.2 | -355.7 | 15.0 |
| amber20-cellulose | 610 | 1665.5 | 2878.6 | 1508.4 | -1511.9 | 0 |

- With passes split, Metal starts the PME chain while the list build still runs, across the command buffer boundary, even though both read posq. So read-only bindings don't serialize passes, and the mechanism the split relies on exists on the M3 Ultra.
- Nothing overlaps the chain after it: gridInterpolateForce writes the force buffers that bonded and nonbonded write, so they wait for it. The pmeForce fold removes that dependency.
- Normal batching (the buffers records of the same runs) never overlaps them: the buffer holding the chain starts 0.3 to 0.6 us after the list build's buffer ends, in all 2160 apoa1pme steps and 5829 pme steps. My reading: the list build shares one encoder with the clears, which write pmeGrid1, and the chain's encoder binds pmeGrid1, so the chain waits for that whole encoder.

### 22:35Z Candidate a94e50b43 prepared (branch cand/pmepass, not pushed)

While splitvar waits for the lease I wrote the production form of the split plus fold, so it can be gated and screened in the same queue cycle. Worktree /Users/amir/code/mini/ultra-pme-pass, one commit on 17929e631, 113 lines added and 11 removed:
- MetalQueue::splitPass() ends the open encoder without committing. dispatch was asked for this API (cand/splitpass); my commit carries a 3-line version until theirs lands.
- MetalCalcNonbondedForceKernel::initialize turns the path on for PME and LJPME, with no PME queue and no CPU PME, when getMultiprocessors() is 16 or more. The M2 (10 cores) stays off, since the lab fold cost it about 1%. Nothing between 10 and 60 cores is measured.
- A pre computation ends the pass before the list build, and execute() ends it before and after the reciprocal kernels.
- commonInitialize takes separatePmeForces (default false, so other platforms are unchanged). gridInterpolateForce stores into pmeForce (pmeDispersionForce for LJPME) under USE_PME_FORCE_ARRAY, and AddPmeForcesPostComputation adds them with pme.cc's addForces after nonbonded.
- No bonded split yet: splitvar's pmefb against pmef decides it.

Builds: the M3 Ultra tree is ultra-pme/cand3 (build.sh), and the M2 tree is ~/lab/ultra-pme/passon, with the core threshold forced to 1 (lab only) for the bitwise check against 17929e631 (m2passon.sh). I also changed splitvar.sh before its hold: the splitb arm became skipi (serial, interpolation skipped), because the design's kill rule needs B/A = splitskipi/skipi.


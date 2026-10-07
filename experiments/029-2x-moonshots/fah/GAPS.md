# Folding@home readiness: what passes, what fails, what's missing

2026-09-27. Code: branch `r2/fah` (48223affc, 7c2486c27) on `ultra/integrated` b0c76cb7c, OpenMM 8.6.0 development. Hosts: M3 Ultra (60-core GPU, macOS 27.2) and M2 (10-core GPU, 8 GB, macOS 27.2). Tolerances are the alchemiscale-fah defaults: 5 kJ/mol/nm per-atom force and 10 kJ/mol energy against Reference.

## Harness

Everything here reruns from this directory.

- `corpus.py <openmm src> <out>` builds FAH-style work units (system, state and integrator .xml.bz2) on the CPU platform.
- `run.sh <tree> <corpus> <out>` runs each unit on Metal in single and mixed in one correctness ticket, saving positions, forces, energy and integrator globals at step 0 and 5 checkpoints. It then compares every snapshot against Reference with `wu.py compare`.
- `restart.sh` and `restart.py` cover binary checkpoints, XML restart, NaN and rollback.
- `neqwork.py` samples protocol work over full switching cycles on any platform.
- `audit.py` checks CustomIntegrator expressions for the operations df64 mixed lacks, statically from XML or by compiling on Metal mixed.

| Unit | Atoms | What it covers |
| --- | ---: | --- |
| tip3p-hmr | 29451 | amber14 + TIP3P, PME 0.9 nm, HBonds, 4 amu hydrogens, LangevinMiddle 4 fs, MonteCarloBarostat every 25 steps, constraint tolerance 1e-6 |
| tip4pew | 38876 | amber14 + TIP4P-Ew virtual sites, PME, HBonds, LangevinMiddle 2 fs, MonteCarloBarostat |
| neq | 2269 | alanine dipeptide in TIP3P. It has softcore sterics (CustomNonbondedForce with interaction groups) and charge offsets on a NonbondedForce global. A CustomIntegrator (V R H O R V, feflow style) moves lambda every step and accumulates protocol_work, 250 steps per leg |
| gbsa | 2489 | amber14 + OBC2 (CustomGBForce), NoCutoff, HBonds, LangevinMiddle 2 fs |

## Results

### Forces and energies along the trajectory

2500 steps (neq 1000), 6 snapshots each, max over snapshots.

| Unit | Precision | M3 Ultra max\|dF\| | M3 Ultra max\|dE\| | M2 max\|dF\| | M2 max\|dE\| | Verdict |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| gbsa | single | 0.012 | 0.046 | 0.011 | 0.046 | PASS |
| gbsa | mixed | 0.146 | 0.047 | 0.121 | 0.044 | PASS |
| neq | single | 0.182 | 0.062 | 0.169 | 0.049 | PASS |
| neq | mixed | 0.174 | 0.057 | 0.224 | 0.053 | PASS |
| tip3p-hmr | single | 0.375 | 0.522 | 0.297 | 0.569 | PASS |
| tip3p-hmr | mixed | 0.903 | 0.601 | 0.625 | 0.560 | PASS |
| tip4pew | single | 0.482 | 0.479 | 0.657 | 0.346 | PASS |
| tip4pew | mixed | 0.534 | 0.426 | 0.717 | 0.455 | PASS |

The M3 Ultra columns are the worse of two runs, r1 (all eight) and r2 (the four explicit-solvent rows). Mixed shows a larger max|dF| than single for one reason. Both Metal modes compute forces from float positions, while Reference gets the double positions. Per force group, gbsa forces are identical in single and mixed and equal OpenCL single; the bonded part's 0.098 is float position rounding. Speed: 2500 steps of tip3p-hmr take 1.5 s in single on the M3 Ultra and 5.1 s on the M2 (7.5 s mixed). The M2 ran its pinned base, 8ae6cf17b, not r2/fah (the round 2 df64 and correctness merges are missing there), and its 8 GB held every unit. M2 results: `results/corpus-m2.txt`.

### Constraints

| Precision | Worst relative constraint error |
| --- | --- |
| single | 7.7e-6 to 9.4e-6 at requested 1e-6. The float position limit (0.1 nm bonds at 5 nm coordinates). The CPU-built step-0 state carries the same 7-9e-6. |
| mixed | 5.1e-7 at 1e-6 and 3.1e-8 at 1e-8, the same as the CPU platform. There is one exception, gap 1 below. |

### NEQ protocol work

Each sample is one full forward and reverse cycle of 500 steps, started with fresh seeds and velocities.

| Platform | n | mean | median | sd | max |
| --- | ---: | ---: | ---: | ---: | ---: |
| Metal single | 112 | 191 | 164 to 191 | 88 to 99 | 763 |
| Metal mixed | 112 | 192 | 158 to 183 | 89 to 107 | 686 |
| CPU | 16 | 181 | 160 | 82 | 378 |

Units are kJ/mol. Medians and sds are shown as the ranges of the two batches (16 and 96 seeds). The distributions agree. One r1 single run ended at 1088 kJ/mol, a tail event of a 0.5 ps switch.

### Restart and failure behaviour

`results/restart.txt`: 16 runs, 4 units x 2 precisions x DeterministicForces off and on.

| Check | Result |
| --- | --- |
| Binary checkpoint into a fresh Context | PASS 16/16. Positions, velocities, CustomIntegrator globals and per-DOF values come back bit for bit. |
| Bitwise continuation, DeterministicForces | neq and gbsa: bitwise (dx 0, d(work) 0). tip3p-hmr and tip4pew: bitwise in 1 of 4 runs, otherwise 0.0009 to 0.27 nm apart after 200 steps. Not a Metal bug (gap 3). |
| XML restart (state + integrator XML into a fresh Context, the FAH path) | PASS 16/16. Globals and per-DOF values are bit for bit; positions within 7.3e-7 nm (one float ulp from imaging); velocities exact. XML has no RNG state, so the continuation is a new stochastic path by design. |
| NaN coordinate | PASS 16/16, never a stale finite result. neq raised "Particle coordinate is NaN". The explicit units and gbsa returned a NaN energy (gap 2). |
| Rollback into the same Context | PASS 16/16. Energy matches the saved one, within 0.043 kJ/mol of 4.7e5 in single, and the continuation is finite. |
| Precision=double | Fixed, 48223affc. It used to be accepted and then failed inside MSL compilation; it now throws "The Metal platform does not support Precision=double ..." at Context creation. `testDoublePrecisionRejected` in TestMetalMixedPrecision covers it. |
| Command-buffer error reaches the caller | Fixed by reading, 7c2486c27. MetalQueue::commit already threw, but MetalEvent::wait() and poll() returned normally on a failed buffer, and callers read pinned results the buffer never wrote (neighbor-list counts, CCMA convergence). Both now throw. 24 fault probes (out-of-bounds reads, writes and atomics at 256 MB to 256 GB, purgeable-empty buffers) and a 30 s spin never failed a buffer on macOS 27.2 (gap 4), so the host path is tested through a test-only hook instead: r2/fah-hook 095a35786, CMake OPENMM_METAL_TEST_HOOKS (off by default, compiled out), OPENMM_METAL_TEST_FAIL_CB=n fails the nth status check with a page-fault NSError. `diag/cbhook.cpp` PASS on tip3p-hmr and tip4pew mixed: the throw lands mid-run (steps 749 and 746) with "Error executing METAL command buffer: ... (MTLCommandBufferErrorDomain error 3.)", the Context is destroyed with no hang, and a fresh Context in the same process runs 1000 steps to a finite energy; 6-7 s per process. The hook reaches only the MetalEvent path (wait and poll), which runs fewer than 200 times in 10000 steps. The main catch for a failed buffer is MetalQueue::commit, which throws on every completed buffer it retires and already did before 7c2486c27. Gap 4 is closed on this evidence (2026-09-28). r2/fah-hook stays a test-only branch, outside trunk and the upstream reorder. The real-fault behavior stays an item for FAH. |

`gate.sh --quick` on r2/fah: PASS, 6 tests x 2 precisions (`results/gate-quick.txt`).

### Mixed-precision function audit

`audit.py` (results in `results/mixed-audit.txt`). In mixed, Metal evaluates CustomIntegrator per-DOF and sum expressions in df64. Eleven operations have no df64 version: tan, asin, acos, atan, atan2, sinh, cosh, tanh, erf, erfc, and pow with a non-integer exponent. Global expressions run on the host in double, and force expressions run in float in both modes, so neither is affected.

| What | Result |
| --- | --- |
| This corpus: the neq integrator (10 per-DOF and sum expressions) and the LangevinMiddle units | None of the eleven. |
| Every CustomIntegrator in openmmtools main (17 classes, 4 to 46 per-DOF and sum expressions each), including PeriodicNonequilibriumIntegrator, which feflow's NonequilibriumCyclingProtocol builds for alchemiscale-fah | None of the eleven. All 17 compile and run 20 steps on Metal mixed with the neq system. |
| feflow's protocol file, statically | None of the eleven. |
| Negative control: tanh(v) and abs(v)^1.5 per DOF | The audit flags both. Metal single runs. Metal mixed refuses at Context creation (b38436494): "Metal mixed precision cannot evaluate tanh in the CustomIntegrator step 0 expression '...'". Before that commit it failed at the first step with "call to deleted function 'tanh'". |
| Force expressions using all eleven (CustomNonbondedForce, CustomBondForce) | Run in single and mixed, dE 1.3e-6 and max\|dF\| 6.9e-8 against Reference. |

So no public FAH-adjacent integrator hits the limit. Two things stay open. Private project integrators need the same scan (`audit.py xml <WU dir>`). The refusal now comes at Context creation with the operation and expression named (gap 6, fixed on r2/fah-baro).

## Accuracy contract

Three separate claims. Neither benchmark speed nor any one of these implies the others.

### Numerical

- Single: forces and integration in float, forces accumulated in 64-bit fixed point. Here: 8 of 8 units within 0.72 kJ/mol/nm (M2) and 0.90 (M3 Ultra) of Reference; constraints about 8e-6 relative, the float position limit.
- Mixed: forces in float from float positions. Integration and position corrections run in df64 (paired floats), stored as IEEE double on the current tip. It is not hardware FP64 and does not keep every host-double bit. If round 3's pair storage lands, the contract text changes to match what ships.
- Constraints at requested 1e-8 must be no worse than r1 on both chips: r1 measured about 3.1e-8 (SETTLE) and 2.3e-8 (SHAKE), and this branch measured 3.1e-8. Don't advertise 1e-8 as achieved.
- Unsupported precision or expression features fail clearly before a work unit is accepted. Precision=double does, since 48223affc. The eleven df64 functions do on r2/fah-baro (b38436494, gap 6).
- Drift: the r1 DHFR tight-PME numbers (mixed -4.4e-6 ± 5.7e-6 kT/ns/dof over 10 runs) are the reference. The final stack reruns that protocol.

### Reproducibility

- With DeterministicForces, force bits repeat for the same build, device and neighbor-list history. Two fresh Contexts from one checkpoint run bit for bit together here. The original run and a reload of its own checkpoint do not (gap 3), and neither does any pairing across vendors.
- Same-seed trajectories reproduce within that configuration. Energy sums in single are not bitwise; they agree to about one float ulp of the total.
- Restart preserves the RNG (binary checkpoint), CustomIntegrator globals and per-DOF state, position corrections and velocities. Measured here: all bit for bit.

### Deployment compatibility

Separate from both of the above, and unproven. A work unit counts as supported only when the harness bar below passes with FAH's packaged core.

## Harness bar for deployment

The bar is set by the round 3 architecture review. Each step must pass on a clean Mac with a packaged, signed arm64 core, with no Xcode, Homebrew or development OpenMM installed.

| Step | Covered by this harness today |
| --- | --- |
| Assignment of a WU to an Apple GPU | No. Needs client PR 455, cbang 213 and the assignment server. |
| Explicit Metal selection | `minicore/` selects Metal and the precision from flags, in C++ with no Python. |
| Full run of a real WU | Only for synthetic units. `minicore/pilot.sh smoke` runs each unit end to end (25000 steps) from its XML files. |
| Interrupt and restart | `minicore/killtest.sh` kills the core with SIGKILL 10 times at random points, crashes it inside a checkpoint write, and truncates a checkpoint. CPU dry run passes all three; Metal runs after 07:00Z. |
| Validation | Only against Reference, at the public alchemiscale-fah tolerances. minicore runs that force check before the first step. Not FAH's validator. |
| Upload and accepted credit | No. |
| Clean machine, packaged arm64 core | Partly. `minicore/package.sh` builds a bundle (core, libOpenMM, Metal, CPU and PME plugins) with no path outside the bundle and the OS, hardened runtime, run from an empty environment at nice 19 and darwin background priority. Not yet a second Mac, and not as user nobody. |

## Open gaps, ranked

1. **Fixed on r2/fah-baro (7410fcb42): mixed-precision reorders rounded wrapped atoms to float.** Common code, so CUDA, OpenCL and HIP mixed share it, upstream master included (ccc08b118).
   - Mechanism: `ComputeContext::reorderAtomsImpl` moves each molecule whose center left the box back inside by subtracting a float shift from posq, and leaves posqCorrection alone. A molecule wrapped in from the low side rounds each atom to a float ulp of the box, independently, so bond lengths change.
   - Evidence (`diag/reorder.py`, tip4pew mixed, 760 steps): relative constraint error of 3.3-8.8e-6 at every reorder step (251, 502, 753) in 3 of 3 seeds with the barostat removed, and at the same steps with it, accepted or rejected. No other step goes over 1e-6. I first blamed the barostat's save and restore. That was wrong: energy evaluation never reorders, and 2 of 5 rejected seeds against 0 of 2 accepted is a 10/21 coincidence.
   - Fix: shift by whole box vectors in double and split the result back into posq and posqCorrection. After it, the same runs show no step over 1e-6 (5 of 5, with and without the barostat), and 64 wrapped particles round-trip to 7e-15 nm, down from 4.3e-7 (`diag/wrap.py`). Test `testReorderWrapKeepsPositions`, quick gate PASS.
2. **With a cutoff, a NaN coordinate raises only at the next reorder (every 250 steps). Without one, it never raises.** Between reorders the energy goes NaN and the core has to catch it. This is shared upstream behaviour (the check lives in `ComputeContext::reorderAtoms`), and FAH cores already treat NaN energies as bad states. It needs confirming against the core's real check once FAH shares it.
3. **Closed, matches the OpenMM contract: a resumed run is not bitwise equal to a straight one.** Decision 2026-09-28: bitwise continuation is not a release gate. OpenMM's docs say a checkpoint lets you continue exactly only where the platform and methods are deterministic, and no public core22 policy asks for bitwise restarts. What a release must show is that the checkpoint restores all integrator and RNG state (every load below is exact) and that the continuation is statistically sound (averages within one block se). Upstream OpenCL on this Mac behaves the same way (sub-bullet below). The history: DeterministicForces is bitwise only for the same neighbor-list history. Two fresh Contexts loaded from one checkpoint agree bit for bit (dF 0, dx 0, all six runs). The original Context reloading its own checkpoint does not: its first force differs by 0.004 to 0.008 kJ/mol/nm. `loadCheckpoint` does not force a list rebuild, in CUDA and HIP as well as Metal. Each tile packs 32 interacting atoms chosen at the last rebuild, so float sums inside a tile depend on when the list was built. OpenMM does not promise identical continued trajectories. A rebuild in `loadCheckpoint` would make reloads agree with fresh Contexts, but not with the original run, so I left it.
   - Kill test with a per-step trace (2026-09-28, `pilot.sh restart`, tip3p-hmr, 5000 steps, 8 kills in 9 starts). Every one of 16 loads gave positions, velocities, box and step count bitwise equal to what the killed run had at that step. The restart at step 500 loaded a state bitwise equal to the straight run, and the runs differed from step 501, the first step after the load. The same holds with the barostat off (frequency 0), so the barostat is not the cause. A new Context starts with `forceRebuildNeighborList` set (MetalNonbondedUtilities.cpp:61), so a resumed process computes step 501 with a list built at step 500. Over 500 samples the averages agree within one block standard error: PE -395282 against -395177 kJ/mol (se 469 and 478), T 300.08 against 299.82 K (se 1.3). Barostat off: PE -393923 against -394042 (se 580), T 299.44 against 299.19 K (se 1.2).
   - The barostat has a restart gap of its own. `MonteCarloBarostatImpl` keeps `step`, `volumeScale`, `numAttempted` and `numAccepted` as members that no checkpoint saves, so a new Context goes back to volumeScale = 0.01*V while the straight run has been adapting it. With the barostat on, the box first differs at step 750. Upstream knows: [openmm#2202](https://github.com/openmm/openmm/issues/2202) (open since 2018) reports NPT runs diverging after the first barostat step following a checkpoint load. [openmm#2400](https://github.com/openmm/openmm/pull/2400) (merged 2019) moved the barostat random numbers onto the checkpointed generator, but volumeScale and the counters are still reset on master. An OpenMM fix is about 150 lines: a no-op `createCheckpoint`/`loadCheckpoint` pair on `ForceImpl`, called from `ContextImpl` after the integrator, then implemented in the four MonteCarlo barostat impls and the RPMD barostat, plus a test. Every platform picks it up. A minicore-only fix isn't possible, because the members are private and `Context` doesn't expose its ForceImpls.
   - Core-side fix candidate: `minicore --fresh-context` calls `Context::reinitialize(true)` after each checkpoint write. That is a createCheckpoint/loadCheckpoint round trip into a new ContextImpl, the same path a resumed process takes, so the straight run and a resumed run share the list build and the barostat reset at every checkpoint. `pilot.sh fresh` tested it on tip3p-hmr and tip4pew (20000 steps, 10 kills in 11 starts each). It failed. The killed and mid-write runs still differ, and the mid-write run has a single restart at step 1000. So a reinitialize inside a process and a new process loading the same checkpoint don't agree, and some state lives outside both the checkpoint and ContextImpl. Cost, for when it works: reinitialize takes 0.23-0.33 s. Of that, Metal compiling is 0.002-0.003 s (17 libraries) plus 0.005-0.012 s (52 pipelines) once the process has compiled them once. The first Context build in a process takes 0.62-0.80 s, 0.36-0.45 s of it library compiles. Footprint across 20 reinitializations stays in 480-628 MB with no steady growth.
   - OpenCL on this Mac, same check (2026-09-28, `pilot.sh opencl`, upstream OpenCL platform, single, tip3p-hmr, 1000 steps, --trace). Two straight runs in separate processes agree at every step. A run stopped at step 500 and resumed in a new process loads a state equal to the straight run's step 500 and first differs at step 501 (positions and velocities, not a barostat step); the box first differs at step 550. Over 100 samples PE is -397152 against -397193 kJ/mol (se 854 and 841), T 293.79 against 293.72 K (se 1.9). Same pattern as Metal.
   - What the checkpoint restores, from source: `IntegrationUtilities::createCheckpoint` (IntegrationUtilities.cpp:913-925) writes `randomPos`, the consumption offset into the prefetched Gaussian pool, then the whole pool and the per-thread seed state, and `loadCheckpoint` reads all three back. The update-state checkpoint also saves atom order, cell offsets and `stepsSinceReorder`, so the refill and reorder schedules continue unchanged. What diverges at step 501 is therefore the force at the loaded step-500 state, not the RNG or a reorder: a new Context builds its neighbor list at the load (`forceRebuildNeighborList`), the straight run uses a list from its last rebuild, and the tile sums round differently (round 1: first force 0.004-0.008 kJ/mol/nm apart). Positions and velocities at step 501 are the first quantities that force touches.
4. **The command-buffer error path has no test.** Nothing I tried makes macOS 27.2 fail a buffer. FAH's core source or a Metal debug layer (MTL_DEBUG_LAYER with a deliberate validation error) is the next thing to try.
5. **Single precision holds constraints to about 8e-6 relative, not the requested 1e-6.** Positions are float. Any single-precision GPU platform behaves the same. It matters only if a project's validator checks constraint tolerance in single.

6. **Fixed on r2/fah-baro (b38436494): a mixed work unit that uses one of the eleven df64-less functions per DOF failed at its first step with a raw compiler message.** `MetalIntegrateCustomStepKernel` now checks every per-DOF and sum expression and the kinetic energy expression when the Context is created, and names the operation, the step and the expression. Metal-side only, no Common change. The tanh and ^1.5 control is refused in mixed and runs in single. Globals that use tanh, erf and ^1.5 still run (BAOAB and GHMC controls in TestMetalMixedPrecision), and all 17 openmmtools integrators still compile and run 20 steps on the new build (`results/mixed-audit-b38436494.txt`).

## Pilot: what's left

FAH projects set `<precision>mixed</precision>` in core.xml (perses `fah_generator.py`, choderalab/men1, the core22 launch project 11733), so the pilot runs mixed; single stays covered. What a real core needs to run one WU end to end on Metal, in order. Gaps 2, 3 and 5 don't block it: cores already treat a NaN energy as a bad state (minicore checks the energy after every chunk), gap 3 only affects bitwise continuation, which OpenMM doesn't promise, and gap 5 is the float position limit every single-precision GPU has.

1. **Core signing.** Measured with the minicore bundle: under the hardened runtime, which notarization requires, ad hoc signed dylibs fail to load with "mapping process and mapped file (non-platform) have different Team IDs". FAH has to sign the core, libOpenMM and every plugin with one Developer ID, or link Metal statically. `package.sh` turns library validation off for ad hoc test bundles only (`adhoc.entitlements`). Linking Metal statically works: `minicore/static.sh` builds one executable with no dylibs of its own, and it passes `pilot.sh smoke mixed` (pilot table).
2. **Running as nobody from a LaunchDaemon.** The v8 client installs `/Library/LaunchDaemons/org.foldingathome.fahclient.plist`, its control names say it runs as nobody, and the idle priority is nice 19 (foldingathome.org v8.4 client guide and priority FAQ). The Metal plugin writes no files itself (it compiles from source in memory; `TempDirectory` is unused). Tested with sudo on 2026-09-28, bundle from ultra-integrated 6f6320bcd, gbsa, 1000 steps: `sudo -u nobody env -i` at nice 19 passes the force check (max|dF| 0.0086) and finishes. A LaunchDaemon with `UserName` nobody, `Nice` 19, `ProcessType` Background and `RunAtLoad` also exits 0 with the same force check and a 293 MB footprint. So the Metal device and the shader compiler both work for nobody outside a login session. One packaging rule came out of it: nobody can't traverse a home directory with mode 750, so the installer must put the core somewhere world-traversable, not under a user's home. Correction (r3-fah, 2026-09-29): on macOS 15 and later the client does not run as nobody. fah-client-bastet's `install/osx/scripts/postinstall` creates a `_fahclient` user (uid 499 down to 200, home /var/empty, group nobody) and patches the plist's `UserName` to it; nobody is the fallback only below macOS 15. This Studio has `_fahclient` uid 499 from a March 2026 client install. Apple's compiler caches what the plugin compiles in the running user's `getconf DARWIN_USER_CACHE_DIR`, under `com.apple.metal`: the nobody run above left 956 KB in /var/folders/zz/.../C/com.apple.metal. For `_fahclient` that is /var/folders/0b/.../C/com.apple.metal, which holds nothing yet. Apple documents no size limit or eviction for it. The lab user's cache holds 8.5 GB in 13 numbered generations of functions and libraries files, all written 2026-09-25 to 09-29, in a directory created 2026-05-11, so old generations do get dropped; what bounds the total is unknown. Per work unit the growth is small: prof/cachegrow.py (2026-09-29) built three TIP3P boxes of new sizes (3834-4482 atoms, PME, Metal mixed) and each first Context added 0.5-0.6 MB to the cache and took 6.3-8.7 s to build and run 10 steps; the same box again added 0.0 MB and took 0.5-0.8 s. A client that sees a new project pays the compile once, and the 8.5 GB here is lab build churn, not per-system growth.
3. **Platform properties.** The core may pass only DeviceIndex, DeviceName, Precision, UseCpuPme, DisablePmeStream, DeterministicForces, TempDirectory and UseBlockingSync. Any other name, for example OpenCL's OpenCLPlatformIndex, fails Context creation with "Illegal property name". DeviceIndex accepts only 0.
4. **macOS version.** The dylibs say minos 11.0, but the plugin compiles MSL 3.2, which needs macOS 15. The SDK marks MSL 3.2 and the MTLCompileOptions `mathMode` and `mathFloatingPointFunctions` setters `API_AVAILABLE(macos(15.0))` (MTLLibrary.h:220, 332, 338), and the plugin builds with -mmacosx-version-min=10.7. On macOS 14 the platform still registers (speed 40), and a Context reaches `setMathMode:`, an unrecognized selector there: an Objective-C exception that aborts the core, not an OpenMMException. Read from the headers and metal-cpp; no macOS 14 Mac was available to run it. Fix: `MetalPlatform::contextCreated` throws "The Metal platform needs macOS 15 or later and an Apple7-family GPU (M1 or later)" when `isPlatformSupported()` is false (r2/fah-baro 6d4e9b81a; registration is skipped too, so OpenCL or CPU gets picked; 12 Metal unit tests pass and Metal registers at speed 100 with no load failures on this Mac), and the FAH core builds with CMAKE_OSX_DEPLOYMENT_TARGET=15.0 so dyld refuses it on macOS 14 before `--info` passes. The assignment server should still gate on macOS 15 and Apple7.
5. **Checkpoint integrity.** `ContextImpl::loadCheckpoint` reads without checking the stream state (ContextImpl.cpp:474-503, shared upstream), so a truncated file is not sure to be refused. minicore writes to a temporary file, syncs and renames, and adds a length and hash footer. Whatever Core28 does, the kill test checks the Metal side of it: a fresh process resumes from the last good checkpoint.
6. **Command-buffer faults (gap 4).** `diag/cbfault.cpp` spins one GPU thread on a flag until the watchdog kills the buffer or the host releases it after 30 s. If the watchdog fires, OpenMM must raise an OpenMMException. Shader validation (MTL_SHADER_VALIDATION) only logs out-of-bounds accesses by default, so it can't fail a buffer. The probe holds the GPU for up to 30 s, so it needs an exclusive hold.
7. **Multi-hour units.** MetalQueue creates every command buffer and encoder inside an autorelease pool, so nothing per step should pile up. minicore logs the process footprint at every checkpoint. `pilot.sh soak` ran tip3p-hmr (29451 atoms, PME, barostat) for 200000 steps (800 ps) in 110 s. The footprint went 494 MB at step 10000, 428 MB at 40000, then 383.4-383.8 MB from step 60000 to 200000. That's flat, with no growth. Total energy stayed between -320960 and -319460 kJ/mol. 110 s is not multi-hour, so this rules out a per-step leak, not one that shows up on an hours-long scale.

### Pilot runs, 2026-09-28

Bundle from ultra-integrated 6f6320bcd (00b3715be reorder fix, 6b3d5c1e3 df64 refusal, fc556d3d7). Rows without a precision are single; mixed rows ran in `work-mixed`. Every run used an empty environment, nice 19 and darwin background, one core at a time, one correctness ticket per row.

| Run | Result |
| --- | --- |
| `pilot.sh smoke` | PASS. All four finish with no plugin load failure. Force check max\|dF\| and \|dE\|: gbsa 0.0086 and 0.046, neq 0.124 and 0.0014, tip3p-hmr 0.238 and 0.159, tip4pew 0.415 and 0.0078. 25000 steps take 19-29 s. |
| nobody, `sudo -u nobody env -i`, nice 19 | PASS. gbsa 1000 steps, max\|dF\| 0.0086. |
| LaunchDaemon, UserName nobody, Nice 19, ProcessType Background | PASS. Exit 0, same force check, 293 MB footprint. |
| `pilot.sh kill` | PASS. gbsa (10 kills) and neq (5 kills) end bitwise equal to the straight run, neq protocol_work 119.86179399490356 in both. tip3p-hmr (10 kills) finishes but differs (gap 3). The mid-write crash and truncated checkpoint recover in all three. No minicore left afterwards. |
| `pilot.sh soak` | PASS as a leak check. tip3p-hmr, 200000 steps in 110 s. Footprint 494 MB, then 383.4-383.8 MB from step 60000 on. |
| `pilot.sh smoke mixed` | PASS. All four finish with no plugin load failure. Force check max\|dF\| and \|dE\|: gbsa 0.119 and 0.043, neq 0.124 and 0.0009, tip3p-hmr 0.494 and 0.185, tip4pew 0.440 and 0.030. 25000 steps take 11-36 s, footprint 392-554 MB. gbsa's larger mixed max\|dF\| is float positions against Reference's doubles, as in the corpus table. |
| `pilot.sh kill mixed` | PASS. gbsa (8 kills) and neq (4 kills) end bitwise equal to the straight run, neq protocol_work 111.72331142733674 in both. tip3p-hmr (10 kills) finishes but differs (gap 3). The mid-write crash and truncated checkpoint recover in all three. |
| `pilot.sh soak mixed` | PASS as a leak check. tip3p-hmr, 200000 steps in 127 s. Footprint 591 MB at steps 10000-20000, 527 MB at 30000-40000, then 484.3-484.6 MB from step 50000 to 200000. Energy stayed between -321636 and -318702 kJ/mol. |
| `pilot.sh opencl` | Upstream OpenCL, tip3p-hmr: straight runs repeat bitwise; a resume at step 500 loads exactly and differs from step 501, like Metal (gap 3). |
| `pilot.sh restart` | Every checkpoint load is exact. The restart difference starts at the first step after the load, with or without the barostat (gap 3). |
| `cbhook`, hook build, OPENMM_METAL_TEST_FAIL_CB=2 | PASS on tip3p-hmr and tip4pew (see the command-buffer row). With n=200 no unit reached 200 status checks in 10000 steps: wait-free list sizing leaves few waits. |
| `cbfault 30`, exclusive hold | No fault. The first try failed to compile (`restrict` instead of `RESTRICT`). The fixed probe (ticket 59046, 22:30Z) spun one thread 30 s and the host released it: "no error after 30.0 s". macOS kills no compute buffer at 30 s, as at 120 s in 004 and 008, so a spin can't inject gap 4 either. |
| `pilot.sh smoke mixed`, static core | PASS. `minicore/static.sh` on the r2/fah-baro 10f769161 static build: one executable, no plugins dir. max\|dF\| matches the dynamic bundle (0.1193, 0.1244, 0.4936, 0.4402). \|dE\| 0.043, 0.029, 0.537, 0.381 and footprint 565-638 MB, against 0.043, 0.0009, 0.185, 0.030 and 392-554 MB for the 6f6320bcd bundle. r2/fah-baro sat on b0c76cb7c, about 25 trunk commits behind 6f6320bcd, so that comparison mixed trees. |
| `pilot.sh smoke mixed`, dynamic and static from one tree | PASS. r2/fah-892 11c355268 (trunk 892fb00ca plus the macOS gate and the two CMake fixes), one build, `package.sh` and `static.sh` on the same prefix, one ticket. Dynamic then static: max\|dF\| 0.1194/0.1194, 0.1243/0.1243, 0.4937/0.4936, 0.4401/0.4401; \|dE\| 0.04261/0.04261, 0.000887/0.000877, 0.1844/0.1844, 0.02868/0.02861; footprint 390-637 MB against 393-601 MB; 14-38 s against 13-41 s. Static linking changes nothing measurable. |

## What needs FAH's private core source or the core team

- The exact OpenMM revision Core28 builds on (8.3.1 per Wikipedia's core list, a secondary source; FAH's own core_28 post names no OpenMM version). Also its build recipe, and whether a Metal platform can be a static or dynamic plugin in that build.
  What the public evidence settles (2026-09-29): the core ships its own OpenMM. Core 23's package directory (cores.foldingathome.org/openmm-core-23/centos-7.9.2009-64bit/release/0x23-8.0.3/Core_23.fah/) holds FahCore_23, libOpenMM.so.8.0, the CPU, OpenCL, CUDA and PME plugin libraries, its own libstdc++, libcrypto and libssl (forum.foldingathome.org t=40869: an ldd listing 2023-12-01 and a coredump module list 2023-12-03). The client (fah-client-bastet Core.cpp) unpacks a signed tar of any files and runs FahCore_%02x, so a Metal plugin library rides in the same tar. Core 22 was built from FAH's OpenMM fork (branches core22-openmm-7.4.1 to -7.5.0), whose diff against 7.5.0 patches openmmapi files such as MonteCarloBarostatImpl.cpp; cores 23 to 28 build from the private openmm-core repo. Consequence: a platform-only change reaches FAH as a plugin; a change under openmmapi or platforms/common reaches FAH only through the core team's OpenMM branch. The barostat trial reorder (priced at about 8 us/step on the explicit units) is such a change and sits on this list.
- How the core picks a platform and maps properties: `-gpu-platform`, device index, Precision, and whether it would pass DeterministicForces.
- The validator: which forces and energies it compares, how often, against what, how it treats NaN, and the retry count. This harness uses the public alchemiscale-fah defaults, which may not be what Core28 runs.
- The checkpoint path. Does the core use `createCheckpoint`/`loadCheckpoint`, or XML state (`checkpointState.xml` appears in logs)? Is there an atomic write, and what happens when it's interrupted mid-write?
- A sponsored WU corpus for Apple testing: real serialized system, state and integrator files, with force classes, custom expressions and precision per project. `audit.py xml` then settles the df64 question for each project.
- The pilot precision and the supported Mac matrix, agreed with FAH.
- Core signing and packaging for macOS arm64: FAH's own signature, Apple notarization, where runtime Metal shader compilation writes its cache.
- A way to inject a GPU fault in a way the core can observe (gap 4).

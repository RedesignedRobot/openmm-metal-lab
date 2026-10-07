# Bet 4: dead; minimizer-only candidate selected

The best SHAKE architecture reaches **0.865962** of ultra-int028’s gbsa single, below the required **0.95**. It improves gbsa mixed by **11.89%**, but would need another **9.70%** throughput gain to meet the target. The minimizer condition succeeds: mixed/single wall ratios are **1.010 on M3 Ultra** and **1.264 on M2**. Both conditions were required, so Bet 4 is dead this round.

Selected candidate: the isolated two-pass minimizer, source `61bbcc20f958bde9d4d55613c6d20d39819f9b4b`. The worktree contains exactly its three CommonMinimize files, byte-identical to the full-gated bench. The SHAKE/COM experiments are archived, not selected. No commit or push was made. Per the GPU-time quota, no further exploratory round is started. All queued V2/V3 screens, minimizer confirmation, M2 checks and deterministic-force work are complete.

## Census first

Frozen baseline: `/tmp/openmm-metal-bench/ultra-int028`, commit `7484d7bef401f813dc871c1e156578954606d4ea`. Raw baseline instrumentation, manifests, source blobs and timings: [census](/tmp/openmm-metal-bench/ultra-m29-mixed/census). Instrumented GPU times are microseconds per step, not benchmark throughput.

| Measurement | Single | Mixed | Mixed excess |
|---|---:|---:|---:|
| Whole fused step | 265.584 | 332.940 | 67.356 |
| Fused integrator | 16.212 | 66.828 | 50.616 |
| COM calculation | 6.643 | 9.675 | 3.033 |
| COM removal | 6.436 | 10.203 | 3.767 |
| Isolated SHAKE dispatch | 17.508 | 68.376 | 50.867 |

The fused integrator accounts for **75.1%** of mixed excess. Isolated SHAKE’s matching excess identifies its serial dependency chain as the main target. COM contributes another **10.1%**. Splitting the kernels adds dispatches and removes overlap, so isolated times are not additive. The census overlapped build load; the interleaved ab.sh screens below supply the throughput verdict.

V1’s instrumented mixed integrator falls to 53.628 microseconds, about 20% lower, but mixed COM calculation/removal remain 9.695/11.237 microseconds. The bundled fold did not deliver a measured COM gain. Raw: [census-v1](/tmp/openmm-metal-bench/ultra-m29-mixed/census-v1).

## Architecture and ratio evidence

All screens use two interleaved 15-second rounds, single and mixed, against ultra-int028 Metal single/mixed and OpenCL single. Ratios are ratios of median ns/day. CPU-load screens are provisional under the review ruling; no quiet 3x30 integration confirmation is claimed.

V1 spreads each SHAKE cluster over an xyz/padding quartet while retaining serial df64 dot sums. V2 replaces those sums with compensated float expansions and error-free product transforms across four lanes. V3 spreads a cluster’s four atoms over sixteen lanes, keeping ordered bond updates while distributing coordinate state and compensated residuals. The kick/state arithmetic retains df64 where its error budget requires it. Free atoms use quartets; SETTLE retains its precise existing per-water arithmetic. These were substantial architecture variants, not retries of float warm starts or relaxed df64 math.

### V3, widest architecture

Source `86660ab42df5b69b227b1919bd2f92cc0550b0d1`.

| Test | S / baseline S | M / baseline M | M / baseline S | M / baseline OpenCL S | Raw ab.sh outdir |
|---|---:|---:|---:|---:|---|
| gbsa | 1.0038 | 1.1189 | 0.8660 | 1.2061 | `~/code/metal/bench.noindex/ultra-m29-mixed-v3/screen-small` |
| rf | 0.9481 | 1.0013 | 0.8398 | 1.5712 | `~/code/metal/bench.noindex/ultra-m29-mixed-v3/screen-small` |
| pme | 0.9989 | 1.0089 | 0.8835 | 1.5277 | `~/code/metal/bench.noindex/ultra-m29-mixed-v3/screen-small` |
| amber20-dhfr | 0.9971 | 1.0078 | 0.8661 | 1.4444 | `~/code/metal/bench.noindex/ultra-m29-mixed-v3/screen-large` |
| apoa1pme | 0.9991 | 0.9548 | 0.8486 | 1.4199 | `~/code/metal/bench.noindex/ultra-m29-mixed-v3/screen-large` |

The gbsa medians are baseline single 1613.768220, baseline mixed 1248.987311, candidate single 1619.961013, candidate mixed 1397.462654, and baseline OpenCL single 1158.623169 ns/day. Both rounds miss 0.95; the shortfall is much larger than their variation. V3 also shows an apoa1pme mixed ratio of 0.955 and an rf single ratio of 0.948, violating the 1% cost rule in this provisional screen. These regressions were not separately confirmed under quiet load; no further rounds are authorized by the final budget ruling. No claim is made that the experiments prove all compensated constraint designs impossible.

### V2, compensated quartet

Source `423efe0a90b3d91aadf3626d8305a482ef8b1dd7`.

| Test | S / baseline S | M / baseline M | M / baseline S | M / baseline OpenCL S | Raw ab.sh outdir |
|---|---:|---:|---:|---:|---|
| gbsa | 0.9920 | 1.0770 | 0.8235 | 1.1430 | `~/code/metal/bench.noindex/ultra-m29-mixed-v2/screen-small` |
| rf | 0.9940 | 1.0184 | 0.8506 | 1.5503 | `~/code/metal/bench.noindex/ultra-m29-mixed-v2/screen-small` |
| pme | 1.0038 | 1.0177 | 0.8948 | 1.5376 | `~/code/metal/bench.noindex/ultra-m29-mixed-v2/screen-small` |
| amber20-dhfr | 0.9959 | 0.9913 | 0.8235 | 1.4177 | `~/code/metal/bench.noindex/ultra-m29-mixed-v2/screen-large` |
| apoa1pme | 1.0200 | 1.0104 | 0.9151 | 1.4947 | `~/code/metal/bench.noindex/ultra-m29-mixed-v2/screen-large` |

### V1, initial cooperative split

Source `5699469191d775222d97980573356e7924852cbc`.

| Test | S / baseline S | M / baseline M | M / baseline S | M / baseline OpenCL S | Raw ab.sh outdir |
|---|---:|---:|---:|---:|---|
| gbsa | 1.0060 | 1.0524 | 0.8094 | 1.1116 | `~/code/metal/bench.noindex/ultra-m29-mixed/screen-small` |
| rf | 0.9929 | 1.0217 | 0.8498 | 1.5357 | `~/code/metal/bench.noindex/ultra-m29-mixed/screen-small` |
| pme | 0.9954 | 1.0081 | 0.8813 | 1.5212 | `~/code/metal/bench.noindex/ultra-m29-mixed/screen-small` |
| amber20-dhfr | 0.9984 | 1.0241 | 0.8784 | 1.4614 | `~/code/metal/bench.noindex/ultra-m29-mixed/screen-large` |
| apoa1pme | 0.9983 | 0.9899 | 0.8826 | 1.4706 | `~/code/metal/bench.noindex/ultra-m29-mixed/screen-large` |

## Selected minimizer and wall times

The default uses mixed/double precision and the backend’s `getSupports64BitGlobalAtomics()` capability. When those atomics are unavailable, reduction kernels write per-block partials, then a second dispatch folds them without global atomics. The block count scales with variables and device workgroups and is capped by the existing energy workspace. Four bands of that workspace hold two partial sums and their destination metadata. No new device buffer or getenv switch is added. The fallback large-gradient scale path retains its direct single-block write. Optional constraint-kernel setup is guarded when there are no constraints.

Changed production files:

- `platforms/common/include/openmm/common/CommonMinimizeKernel.h`: reduction state and finish kernel.
- `platforms/common/src/CommonMinimizeKernel.cpp`: capability selection, workspace binding and two-pass dispatch.
- `platforms/common/src/kernels/minimize.cc`: per-block partials and final reduction.

Raw delivery: [minimizer.patch](/tmp/openmm-metal-bench/ultra-m29-mixed/minimizer.patch). The final worktree matches `/tmp/openmm-metal-bench/ultra-m29-mixed-minimizer/src` for all three files. Its native build is the C++ compile/type check; `git diff --check` passes.

Each minimization uses apoa1pme, tolerance 10, a 200-iteration cap, one warm-up iteration and restored starting positions. Wall time includes the final energy/force retrieval. This is a fixed-cap measurement, not convergence to tolerance 10: final RMS forces remain about 567–569 on baseline and candidate. CPU uses its default thread setting (28 on M3 Ultra).

| Chip / run | Baseline single s | Baseline mixed s | Candidate single s | Candidate mixed s | CPU s | Mixed / single | Mixed speedup |
|---|---:|---:|---:|---:|---:|---:|---:|
| M3 Ultra, initial 2 rounds | 0.930755 | 8.405466 | 0.835659 | 0.916743 | 6.885752 | 1.097 | 9.169 |
| M3 Ultra, 3x30 s | 0.859485 | 7.849194 | 0.854147 | 0.862600 | 5.828598 | 1.010 | 9.099 |
| M2, 2 rounds | 2.581078 | 9.801247 | 2.185420 | 2.763095 | 11.051670 | 1.264 | 3.547 |

Raw directories: [initial M3](/tmp/openmm-metal-bench/ultra-m29-mixed/minimizer), [M3 confirmation](/tmp/openmm-metal-bench/ultra-m29-mixed/minimizer-confirm), [M2 wall times](/tmp/openmm-metal-bench/ultra-m29-mixed/minimizer-m2). The confirmation repeats each arm from restored positions for at least 30 measured seconds in each of three interleaved rounds; every sample is retained. Candidate mixed round medians are 0.771472/0.862600/0.983202 seconds. External compilation/indexing overlapped, so this is **not a certified quiet-load confirmation**. The final GPU-time budget limits the round to these queued results; no further timing round is started.

## M2 standard check

Raw directory: [minimizer-m2-check](/tmp/openmm-metal-bench/ultra-m29-mixed/minimizer-m2-check), copied from `~/lab/ultra-m2.noindex/checks/20260926T203122Z-7484d7bef`. All nine standard tests ran at 2x15 s, both precisions, with a passing force gate. No builds overlapped. The worst median ratio is 0.996449, within the 1% cost limit.

| Test | Single / baseline | Mixed / baseline |
|---|---:|---:|
| gbsa | 0.9995 | 0.9988 |
| rf | 1.0013 | 1.0009 |
| pme | 0.9981 | 1.0009 |
| apoa1rf | 0.9976 | 1.0027 |
| apoa1pme | 1.0010 | 0.9989 |
| apoa1ljpme | 0.9999 | 0.9964 |
| amber20-dhfr | 1.0027 | 0.9970 |
| amber20-cellulose | 1.0004 | 0.9986 |
| amber20-stmv | 1.0008 | 1.0003 |

The supplied summary omitted STMV from its printed table despite executing it. `all-nine-summary.json` independently includes all 72 raw JSON/time files. STMV baseline/candidate peak footprints are 3,734,908,300/3,734,973,848 bytes single and 3,734,875,544/3,734,949,272 bytes mixed. Other median process-footprint differences range from about -10 MB to +6 MB. Mixed minimization’s maximum RSS is 585,416,704 baseline versus 584,957,952 candidate. The implementation allocates no new GPU workspace, but these observations do not establish literally identical process footprints.

## Correctness and limits

- The selected minimizer’s **full gate passed** at `/tmp/openmm-metal-bench/ultra-m29-mixed-minimizer/gate-20260926T195409Z`: force gate plus 134 Metal tests in five parts. TestMetalDrudeNoseHooverMixed and TestMetalDrudeLangevinIntegratorMixed passed on their first standard gate retry after stochastic initial failures. The reviewer explicitly authorized this full gate; no manual full ctest was run.
- Focused LocalEnergyMinimizer single and mixed tests passed on M3 Ultra; mixed passed on M2 in 25.41 seconds. Earlier shader-address-space and absent-constraint-kernel failures were fixed before the selected source was built and gated.
- V1, V2 and V3 each passed the same 12 named single/mixed checks: CMMotionRemover, CustomIntegrator, LangevinMiddleIntegrator, MixedPrecision, Settle and VerletIntegrator. These exercise SHAKE as well as SETTLE and constraints. V3 completed them in 151.90 seconds. All three quick force gates passed. No test tolerances were relaxed.
- V3’s M3 direct constraint check requested tolerance 1e-8 for 1000 steps. Maximum relative bond errors, baseline/V3: gbsa SHAKE 2.261655e-8/2.261664e-8; pme SHAKE 2.261652e-8/2.261556e-8; pme SETTLE 3.084799e-8/3.084798e-8. The baseline’s float bond-target floor persists; these are **not** literal all-errors-below-1e-8 claims. Raw: `constraints-v3/`. Stored LangevinMiddle velocities were not projected by that measurement script and are not used as velocity-constraint assertions.
- **Selected candidate DeterministicForces passed.** Raw `minimizer-detforces.txt`: bitwise forces match within one context, across new contexts and across three fresh processes for gbsa, rf, pme, apoa1rf, apoa1pme and apoa1ljpme in both precisions. Maximum force difference is zero. Total energies are reported as non-bitwise; the test’s contract is bitwise forces.
- Two-chip drift and M2 integration/constraint validation were not run for the discarded architecture. The prepared drift script was not launched. The extra public Apple-family device guard compiled in a separate snapshot but was not runtime-qualified or selected.

The minimizer is a gated review candidate, not a declaration that Bet 4 or every merge criterion passed. Quiet-load keep certification and literal zero footprint growth remain unproven. The isolated minimizer was not separately screened for M3 molecular-dynamics throughput; the M3 tables measure the discarded integration variants. Its common fallback has not been runtime-tested on non-Metal backends lacking 64-bit atomics. Small minimizations can pay the extra finish-dispatch overhead; their performance was not separately measured. No dead float-kick/warm-start/relaxed-math approach was retried, and no out-of-scope force or dispatch architecture was changed.

## Scope extensions

These are measurement and handoff files outside the production scope. Generated builds and raw measurement outputs are identified by their directories above.

- `/tmp/m29-mixed-census-source/platforms/metal/src/MetalContext.cpp`: isolated command-buffer timing instrumentation; not shipping code.
- `census/instrumentation.patch`: preserves the exact census instrumentation for review.
- `prepare_census.py`: constructs the isolated baseline census source.
- `census-run.sh`: runs the baseline single/mixed census through the lease.
- `census-summary.py`: normalizes kernel times per integration step.
- `round.sh`: sequences the READY wait, census, named tests, quick gate and screens.
- `targeted.sh`: runs only the named correctness checks and smoke arms.
- `smoke.py`: validates that each timing arm can run one step.
- `report-ratios.py`: builds the required five-test ratio table from raw ab.sh results.
- `minimize.py`: measures the apoa1pme minimizer and records accuracy/context data.
- `minimizer-run.sh`: interleaves arms and archives source and load evidence.
- `minimizer-tests.sh`: runs the focused minimizer tests.
- `minimizer-round.sh`: queues minimizer tests and timings after the separate build.
- `minimizer-retry.sh`: rebuilds the shader-cast fix and retries only the failed Mixed test.
- `minimizer.patch`: delivers the separate minimizer candidate for review.
- `constraints.py`: copied established 1e-8 constraint measurement harness.
- `drift-eq.py`: copied established equilibrated drift harness.
- `edit_minimize.py` (removed): stale prototype generator superseded by current source and patch.
- `edit_shake.py` (removed): stale prototype generator superseded by current worktree source.
- `report.md`: this report.

- `constraints-v3-run.sh`: measures baseline and V3 constraint errors at1e-8 through a correctness lease.

- `candidate-census-run.sh`: collects V1 kernel timings.

- `candidate-census-round.sh`: builds and queues the isolated V1 census.

- `prepare-v3.py`: constructs the atom-parallel V3 prototype from V2.

- `minimizer-retry3.sh`: runs the corrected optional-kernel guard candidate.

- `minimizer-run-clean.sh`: prepared quiet timing runner, not launched.

- `minimizer-m2-run.sh`: measures remote baseline and candidate minimizer walls and footprints.

- `minimizer-m2-timing.sh`: transfers the remote harness and serializes its M2 GPU ticket.

- `integration-v1.patch`: preserves the first architecture and its measured source.

- `integration-v2.patch`: preserves compensated quartet arithmetic for independent review.

- `integration-v3.patch`: preserves the atom-parallel architecture for independent review.

- `accuracy-v3-run.sh`: prepared equilibrated drift and deterministic-force checks; not launched.

- `integration-v3-device.patch`: preserves the public device-query guard on V3.

- `minimize-confirm.py`: 30-second repeated200-iteration minimizer timing with every raw sample retained.
- `minimizer-confirm-run.sh`: three interleaved confirmation rounds and host-load records; completed as PID15594.

- `minimizer-m2-test.sh`: prepared the focused Mixed minimizer test on M2.
- `minimizer-m2-round.sh`: separates M2 correctness and timing tickets while the standard check retains the job lock, or takes a fresh lock if run afterward.

- `minimizer-detforces.sh`: runs the explicit bitwise deterministic-force check on the isolated minimizer candidate.

Relative paths in this section are under `/tmp/openmm-metal-bench/ultra-m29-mixed/`.

- `/tmp/openmm-metal-bench/ultra-m29-mixed-v2/round.sh`: sequences the frozen variant’s checks and screens.
- `/tmp/openmm-metal-bench/ultra-m29-mixed-v2/targeted.sh`: runs the named constraint and integrator checks.
- `/tmp/openmm-metal-bench/ultra-m29-mixed-v2/smoke.py`: checks timing-arm setup.
- `/tmp/openmm-metal-bench/ultra-m29-mixed-v2/report-ratios.py`: parses the variant’s raw ratios.
- `/tmp/openmm-metal-bench/ultra-m29-mixed-v3/round.sh`: sequences the frozen variant’s checks and screens.
- `/tmp/openmm-metal-bench/ultra-m29-mixed-v3/targeted.sh`: runs the named constraint and integrator checks.
- `/tmp/openmm-metal-bench/ultra-m29-mixed-v3/smoke.py`: checks timing-arm setup.
- `/tmp/openmm-metal-bench/ultra-m29-mixed-v3/report-ratios.py`: parses the variant’s raw ratios.
- `/tmp/m29-mixed-candidate-census-source/platforms/metal/src/MetalContext.cpp`: isolated V1 command-buffer timing instrumentation, excluded from the final tree.

- `~/lab/ultra-m2.noindex/m29-mixed-minimizer-evidence/minimize.py`: permitted M2 copy of the focused test or timing harness.
- `~/lab/ultra-m2.noindex/m29-mixed-minimizer-evidence/minimizer-m2-run.sh`: permitted M2 copy of the focused test or timing harness.
- `~/lab/ultra-m2.noindex/m29-mixed-minimizer-evidence/minimizer-m2-test.sh`: permitted M2 copy of the focused test or timing harness.
- `~/lab/ultra-m2.noindex/m29-mixed-minimizer-evidence/minimizer-m2-round.sh`: permitted M2 copy of the focused test or timing harness.

## Handoff

The chronological log is the run log (not published). Frozen benches, raw manifests, source hashes and the three integration patches preserve the discarded work. The lab remained read-only. Strongest suggestion: review and integrate the isolated minimizer only after the remaining keep qualifications are resolved; close this round’s cooperative SHAKE bet as dead against 0.95.

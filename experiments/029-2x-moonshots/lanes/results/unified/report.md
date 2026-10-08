# Bet 2: CPU FFT over unified memory

Verdict: dead for this round. Apoa1pme single is 0.217x int028 on the Ultra and 0.271x on the M2. Every measured row regresses. Ultra dhfr single is 0.153x in the follow-up; M2 dhfr single is 0.530x. The six-file prototype is archived, and the shipping worktree is clean at 7484d7bef.

## Candidate

The CPU reads and writes the existing shared-storage PME grids. vDSP performs the FFT, with Bluestein transforms for dimensions outside vDSP's native DFT sizes. GPU spreading, convolution, interpolation, bonded forces, and nonbonded math remain their existing implementations. The existing PME queue supplies overlap with the default queue. Shared events order each GPU producer, CPU transform, and GPU consumer. Device queries select the default; no environment switch selects it. DeterministicForces retains VkFFT.


Measured grid metadata: pme uses 56x56x56, apoa1pme uses 98x98x98. Native Accelerate setup queries reject lengths 56 and 98, so both use the Bluestein branch. See vdsp-dimensions.txt and smoke/*-cpu-s.txt.

Archived prototype files (no shipping edits retained):

- platforms/metal/CMakeLists.txt: link Accelerate.
- platforms/metal/include/MetalFFT3D.h: CPU FFT ownership and device-selection declaration.
- platforms/metal/src/MetalFFT3D.cpp: route eligible real transforms to the CPU implementation.
- platforms/metal/src/MetalKernels.cpp: activate the existing PME queue for overlap.
- platforms/metal/src/MetalCpuFFT.h: private implementation interface.
- platforms/metal/src/MetalCpuFFT.cpp: vDSP/Bluestein transforms, bounded line scratch, queried worker count, and shared-event synchronization.

## GPU cost table

Frozen ultra-int028, commit 7484d7bef. Clock: xctrace sampled GPU shader spans, in microseconds per computeNonbonded dispatch. Use the first steady second after 25 fused MD updates, bounded by nonbonded starts. Every selected window has approximately six FFT spans, one spread, and one fused update per step. The final second of the dhfr mixed trace drops shader records, so it is not used. Original traces and the earlier last-window reductions are retained.

| Test | Precision | VkFFT_main (6 spans) | reciprocalConvolution | computeBondedForces | integrateLangevinMiddleFused | Raw trace / reduction |
|---|---|---:|---:|---:|---:|---|
| pme | single | 33.89 | 3.57 | 68.47 | 15.49 | trace (`/tmp/openmm-metal-bench/ultra-m29-unified/profile-baseline/pme-single.trace`), CSV (`/tmp/openmm-metal-bench/ultra-m29-unified/profile-baseline/pme-single-steady.csv`), window (`/tmp/openmm-metal-bench/ultra-m29-unified/profile-baseline/pme-single-steady.json`) |
| pme | mixed | 33.80 | 3.35 | 69.39 | 53.53 | trace (`/tmp/openmm-metal-bench/ultra-m29-unified/profile-baseline/pme-mixed.trace`), CSV (`/tmp/openmm-metal-bench/ultra-m29-unified/profile-baseline/pme-mixed-steady.csv`), window (`/tmp/openmm-metal-bench/ultra-m29-unified/profile-baseline/pme-mixed-steady.json`) |
| apoa1pme | single | 57.98 | 6.42 | 122.64 | 15.34 | trace (`/tmp/openmm-metal-bench/ultra-m29-unified/profile-baseline/apoa1pme-single.trace`), CSV (`/tmp/openmm-metal-bench/ultra-m29-unified/profile-baseline/apoa1pme-single-steady.csv`), window (`/tmp/openmm-metal-bench/ultra-m29-unified/profile-baseline/apoa1pme-single-steady.json`) |
| apoa1pme | mixed | 63.19 | 6.35 | 120.97 | 82.31 | trace (`/tmp/openmm-metal-bench/ultra-m29-unified/profile-baseline/apoa1pme-mixed.trace`), CSV (`/tmp/openmm-metal-bench/ultra-m29-unified/profile-baseline/apoa1pme-mixed-steady.csv`), window (`/tmp/openmm-metal-bench/ultra-m29-unified/profile-baseline/apoa1pme-mixed-steady.json`) |
| amber20-dhfr | single | 31.30 | 3.12 | 75.20 | 15.23 | trace (`/tmp/openmm-metal-bench/ultra-m29-unified/profile-baseline/amber20-dhfr-single.trace`), CSV (`/tmp/openmm-metal-bench/ultra-m29-unified/profile-baseline/amber20-dhfr-single-steady.csv`), window (`/tmp/openmm-metal-bench/ultra-m29-unified/profile-baseline/amber20-dhfr-single-steady.json`) |
| amber20-dhfr | mixed | 25.92 | 2.56 | 66.44 | 52.96 | trace (`/tmp/openmm-metal-bench/ultra-m29-unified/profile-baseline/amber20-dhfr-mixed.trace`), CSV (`/tmp/openmm-metal-bench/ultra-m29-unified/profile-baseline/amber20-dhfr-mixed-steady.csv`), window (`/tmp/openmm-metal-bench/ultra-m29-unified/profile-baseline/amber20-dhfr-mixed-steady.json`) |

The fused kernel includes integration plus SHAKE/SETTLE constraints. Its full span is an upper bound for constraints, not an isolated constraint cost. There are no separate constraint shaders in these selected windows. VkFFT uses the same shader function name for six dispatches; the reported span is their sum. Bonded is the existing combined computeBondedForces shader, including exclusions. Sampled spans are not the host critical path. Builds were present during these captures; no throughput or keep-rule conclusion comes from these traces.

## CPU cost and overlap probes

CPU-only clock: `std::chrono::steady_clock`, 20 workers, 20 warmup pairs then 200 measured pairs. These use the exact validated transform loops without shared-event waits; input normalization is outside the timed spans. Raw CPU cost output (`/tmp/openmm-metal-bench/ultra-m29-unified/profile-candidate/cpu-fft-cost.txt`). No build processes were reported at the profiling lease start.

| Grid / test | Forward median µs | Inverse median µs | Sum of medians µs | Baseline GPU FFT µs/step |
|---|---:|---:|---:|---:|
| 55³ / dhfr | 428.062 | 437.645 | 865.707 | 31.300 |
| 56³ / pme | 308.084 | 322.479 | 630.563 | 33.887 |
| 98³ / apoa1pme | 1255.917 | 1355.021 | 2610.938 | 57.976 |

These diagnostic costs use different clocks and execution environments; their ratio is not the A/B throughput ratio. CPU arithmetic plus its three dispatch_apply stages already costs much more than the GPU work removed. Handoff elimination alone cannot remove this cost.

The candidate apoa1pme trace has 199 paired reciprocal windows in the selected second. Spread-end to convolution-start averages 1860.803 µs, including 524.395 µs of GPU nonbonded overlap. Convolution-end to interpolation-start averages 1892.335 µs, with no nonbonded overlap. The corresponding baseline windows average 77.815 and 59.968 µs, with no nonbonded overlap. This establishes that overlap occurs but leaves most of the reciprocal window exposed. It does not isolate event wakeup time or prove a power/thermal cause. Raw candidate paired windows (`/tmp/openmm-metal-bench/ultra-m29-unified/profile-candidate/apoa1pme-single-overlap.json`), baseline paired windows (`/tmp/openmm-metal-bench/ultra-m29-unified/profile-baseline/apoa1pme-single-overlap.json`).

The candidate pme trace drops some shader records (0.92 spread and 0.80 convolution spans per nonbonded dispatch in the selected window), so its paired-window reduction is retained only as a diagnostic. Candidate apoa1pme also has about 3% missing convolution records; paired-window sample counts are explicit. No sampled shader total is used as the throughput verdict.

Host profiling clock (`time.perf_counter`, B windows) reports pme 2390.64 µs/step versus baseline 379.43, and apoa1pme 4983.15 versus 1141.92. Candidate process CPU/wall ratios (`time.process_time`) are 4.39 and 8.60. These are traced, non-interleaved diagnostics. The untraced A/B screens remain authoritative.

## Ratio table

Two 15 s rounds per arm, medians of ns/day. Denominators are frozen ultra-int028 Metal at the same precision and ultra-int028 OpenCL single. Clock: benchmark.py host `datetime.now()` around `step()`. All sixty runs in the three selected outdirs returned results. These are rejection screens; the conditional 3x30 s confirmation was not opened because no candidate won.

| Test | Precision | Candidate ns/day | / int028 Metal same precision | / int028 OpenCL single | Raw ab.sh outdir |
|---|---|---:|---:|---:|---|
| pme | single | 150.232 | 0.1665 | 0.2871 | screen-small (`/tmp/openmm-metal-bench/ultra-m29-unified/screen-small`) |
| pme | mixed | 136.914 | 0.1733 | 0.2617 | screen-small (`/tmp/openmm-metal-bench/ultra-m29-unified/screen-small`) |
| apoa1pme | single | 65.453 | 0.2173 | 0.3607 | screen-small (`/tmp/openmm-metal-bench/ultra-m29-unified/screen-small`) |
| apoa1pme | mixed | 62.325 | 0.2320 | 0.3435 | screen-small (`/tmp/openmm-metal-bench/ultra-m29-unified/screen-small`) |
| apoa1ljpme | single | 46.466 | 0.1937 | 0.3721 | screen-small (`/tmp/openmm-metal-bench/ultra-m29-unified/screen-small`) |
| apoa1ljpme | mixed | 42.207 | 0.1938 | 0.3380 | screen-small (`/tmp/openmm-metal-bench/ultra-m29-unified/screen-small`) |
| amber20-dhfr | single | 146.107 | 0.1533 | 0.2567 | screen-dhfr-quiet (`/tmp/openmm-metal-bench/ultra-m29-unified/screen-dhfr-quiet`) |
| amber20-dhfr | mixed | 129.985 | 0.1588 | 0.2284 | screen-dhfr-quiet (`/tmp/openmm-metal-bench/ultra-m29-unified/screen-dhfr-quiet`) |
| amber20-cellulose | single | 25.002 | 0.3049 | 0.5292 | screen-cellulose (`/tmp/openmm-metal-bench/ultra-m29-unified/screen-cellulose`) |
| amber20-cellulose | mixed | 23.989 | 0.3220 | 0.5078 | screen-cellulose (`/tmp/openmm-metal-bench/ultra-m29-unified/screen-cellulose`) |

Load caveats: screen-small had no BUILD RUNNING rows, but heavy unrelated Node/Bun activity affected its dhfr first round and its second round. Quiet first-round apoa1pme single was still only 0.2259x int028. The original dhfr result was 0.130x single and 0.165x mixed. Cellulose had no build overlap, with load 4.72–8.21 and other background CPU activity.

The dhfr follow-up directory retains its original name `screen-dhfr-quiet`, but the run was not quiet. Node/Bun/compiler CPU fell to 99.2% and 100.1% before queueing, then backupd and mediaanalysisd became active. Load was 7.05–11.34. Round-two cpu-s overlapped a build and round-two base-s began with BUILD RUNNING. Both are flagged in the raw summary and load log. Single round ratios were 0.152–0.155 and mixed 0.158–0.160. This confirms a large regression under a different load mix, not 1% precision or a thermal cause. No further repeat was warranted given the quiet apoa1pme result, raw CPU transform cost, and M2 regressions.

## M2 result

M2, four queried performance cores, 8 GiB RAM, macOS 27.2. Two 15 s rounds on the same candidate source hash as the Ultra. Baseline commit 7484d7bef, source hash 962ac562afadf240b808b9ceb7f8c07518d41eb9; candidate source hash 40a2106d8b2acbbcfa2d9ac6c9e9617390f8f7d7. Clock: benchmark.py host `datetime.now()` around `step()`. Memory: median peak footprint from `/usr/bin/time -l`, converted to MiB.

Raw remote check: `~/lab/ultra-m2.noindex/checks/20260926T191932Z-7484d7bef`. Local raw artifacts (`/tmp/openmm-metal-bench/ultra-m29-unified/m2-check`) and official summary (`/tmp/openmm-metal-bench/ultra-m29-unified/m2-check/summary.txt`).

| Test | Precision | Base ns/day | CPU FFT ns/day | Ratio | Peak footprint MiB, base → CPU |
|---|---|---:|---:|---:|---:|
| pme | single | 239.769 | 131.529 | 0.5486 | 124.50 → 127.28 |
| pme | mixed | 196.163 | 112.757 | 0.5748 | 127.98 → 132.59 |
| apoa1pme | single | 59.729 | 16.180 | 0.2709 | 297.70 → 296.21 |
| apoa1pme | mixed | 50.817 | 15.227 | 0.2996 | 312.25 → 297.24 |
| apoa1ljpme | single | 44.773 | 14.252 | 0.3183 | 301.79 → 296.16 |
| apoa1ljpme | mixed | 39.517 | 12.966 | 0.3281 | 297.34 → 305.03 |
| amber20-dhfr | single | 247.637 | 131.249 | 0.5300 | 137.52 → 139.05 |
| amber20-dhfr | mixed | 201.520 | 106.753 | 0.5297 | 146.01 → 148.55 |
| amber20-cellulose | single | 13.274 | 5.397 | 0.4065 | 1500.27 → 1500.20 |
| amber20-cellulose | mixed | 11.425 | 5.127 | 0.4487 | 1500.22 → 1500.25 |

All forty runs produced results, with no builds at their start. One-minute load was 1.33–2.86, memory free 61–65%, and Spotlight CPU 0–7%. Every row and every round is slower. The check completed in 1082 s and exited 0, meaning the measurement finished, not that the performance candidate passed.

The harness reports no footprint-growth flag under its coarse threshold. Raw medians nevertheless rise in several rows, including +4.61 MiB for pme mixed and +7.69 MiB for apoa1ljpme mixed. These measurements do not establish the stricter no-growth condition. Throughput alone rejects the arm. No power or thermal counters were recorded, so no wattage or thermal-cause claim is made.

Exact M2 force verdict:

```text
forces gate cand-m29-unified-84469ab524 PASS, 20 s
```

## Validation

Source disposition: cpu-fft-prototype.patch (`/tmp/openmm-metal-bench/ultra-m29-unified/cpu-fft-prototype.patch`) exactly matched all six edited files before its checked reverse application. cleanup.txt (`/tmp/openmm-metal-bench/ultra-m29-unified/cleanup.txt`) records the clean worktree. The measured source and installed build remain under this run's directory, source hash 40a2106d8b2acbbcfa2d9ac6c9e9617390f8f7d7.

Native build/typecheck: MetalCpuFFT.cpp compiled to a native object with CMake's flags; cpu-fft-typecheck.log records exit 0. The official build has also compiled MetalCpuFFT.cpp and linked libOpenMMMetal.dylib. Full build and installation completed at 17:17:39Z, source hash 40a2106d8b2acbbcfa2d9ac6c9e9617390f8f7d7.
CPU-only direct-DFT and 3D spectral/roundtrip oracle: PASS, maximum normalized error 7.74860382e-7 (cpu-oracle.log). GPU FFT oracle: PASS, TestMetalFFTSingle (1.24 s), 100% tests passed out of 1.
gate.sh --quick: PASS. All twelve force rows (six systems, single and mixed) reported ok; exact verdict line: `PASS`. See gate verdict (`/tmp/openmm-metal-bench/ultra-m29-unified/gate-20260926T173535Z/forces-verdict.txt`) and after-ready.log.
forces.py --md 100: PASS (exit 0). All twelve system/precision rows reported ok. Raw forces-md100.txt and after-ready.log retain the exact rows and cutoff reconciliation diagnostics.

Exact md100 verdict rows from after-ready.log:

```text
gbsa            2489    single  1.955e-06  8.007e-03  6.938e-07  ok
gbsa            2489     mixed  1.317e-05  9.293e-02  5.858e-07  ok
rf             23558    single  1.066e-06  1.997e-02  2.847e-07  ok
rf             23558     mixed  2.086e-05  3.732e-01  4.157e-07  ok
pme            23558    single  1.361e-06  1.814e-02  1.379e-06  ok
pme            23558     mixed  1.979e-05  3.343e-01  1.346e-06  ok
apoa1rf        92224    single  1.576e-06  4.136e-02  1.738e-07  ok
apoa1rf        92224     mixed  5.306e-05  7.497e-01  2.464e-07  ok
apoa1pme       92224    single  5.251e-05  2.548e-01  8.686e-07  ok
apoa1pme       92224     mixed  7.427e-05  6.861e-01  8.990e-07  ok
apoa1ljpme     92224    single  5.251e-05  2.515e-01  8.779e-07  ok
apoa1ljpme     92224     mixed  7.468e-05  7.202e-01  9.084e-07  ok
```

detforces.py: PASS. Same-context, new-context and fresh-process forces were identical for all twelve rows, max|dF|=0. Energy-bitwise is a separate diagnostic and reports DIFFERS. Raw detforces.txt and after-ready.log contain the exact results.
Exact deterministic-force results (`PASS` is the final stdout verdict in after-ready.log):

```text
test precision same-context-forces new-context-forces fresh-process-forces energy-bitwise max|dF|
gbsa single identical identical identical DIFFERS 0.000e+00
gbsa mixed identical identical identical DIFFERS 0.000e+00
rf single identical identical identical DIFFERS 0.000e+00
rf mixed identical identical identical DIFFERS 0.000e+00
pme single identical identical identical DIFFERS 0.000e+00
pme mixed identical identical identical DIFFERS 0.000e+00
apoa1rf single identical identical identical DIFFERS 0.000e+00
apoa1rf mixed identical identical identical DIFFERS 0.000e+00
apoa1pme single identical identical identical DIFFERS 0.000e+00
apoa1pme mixed identical identical identical DIFFERS 0.000e+00
apoa1ljpme single identical identical identical DIFFERS 0.000e+00
apoa1ljpme mixed identical identical identical DIFFERS 0.000e+00
PASS
PASS
```

M2: completed, force gate PASS, all forty timing results present, all ten performance rows slower. See the M2 section and raw summary.
Full ctest remains an acceptance item for the full gate. It was not run here, as instructed. No merge candidate is retained.

## Scope extensions

- /tmp/openmm-metal-bench/ultra-m29-unified/ratio-table.md: final ten-row ratio table generated from raw A/B results.
- /tmp/openmm-metal-bench/ultra-m29-unified/m2-table.md: generated M2 throughput and footprint table.

- /tmp/openmm-metal-bench/ultra-m29-unified/tools/m2-table.py: generate M2 ratios and median peak footprints directly from both raw rounds.

- /tmp/openmm-metal-bench/ultra-m29-unified/cleanup.txt: record exact-patch verification and removal of the losing prototype from shipping source.
- /tmp/openmm-metal-bench/ultra-m29-unified/m2-check/: local copies of raw M2 throughput, force and footprint artifacts for the handoff.

- /tmp/openmm-metal-bench/ultra-m29-unified/tools/screen-dhfr-quiet.sh: obtain a dhfr follow-up after unrelated Node/Bun CPU contention subsides, waiting outside the GPU lease.

- /tmp/openmm-metal-bench/ultra-m29-unified/tools/screen-candidate-body.sh: preserve the original A/B implementation behind the duplicate-run guard.
- /tmp/openmm-metal-bench/ultra-m29-unified/tools/screen-cellulose-once.sh: lock the independent ready cellulose screen and reuse its result.

- /tmp/openmm-metal-bench/ultra-m29-unified/tools/cpu-fft-cost.cpp: event-free timing probe extracted from the exact validated transform loops.
- /tmp/openmm-metal-bench/ultra-m29-unified/tools/cpu-fft-cost: compiled CPU timing probe, run only inside the queued profiling lease.

- /tmp/openmm-metal-bench/ultra-m29-unified/tools/ratio-table.py: generate the requested ratio table directly from two raw A/B rounds.

- /tmp/openmm-metal-bench/ultra-m29-unified/tools/overlap.py: reduce reciprocal shader windows and their overlap with GPU nonbonded work.
- /tmp/openmm-metal-bench/ultra-m29-unified/cpu-fft-prototype.patch: preserve the exact measured prototype, including new source files.

- /tmp/openmm-metal-bench/ultra-m29-unified/report.md: handoff with raw evidence links and verdict.
- /tmp/openmm-metal-bench/ultra-m29-unified/tools/shader.sh: copied shader timeline capture with run paths and precision selection.
- /tmp/openmm-metal-bench/ultra-m29-unified/tools/prof.py: copied benchmark profile driver.
- /tmp/openmm-metal-bench/ultra-m29-unified/tools/steady-kernels.py: reduce the first steady second after 25 MD updates, excluding startup and minimization.
- /tmp/openmm-metal-bench/ultra-m29-unified/tools/kernsum.py: copied per-kernel sampled GPU clock reducer.
- /tmp/openmm-metal-bench/ultra-m29-unified/tools/shadertemplate.py: copied shader timeline template generator.
- /tmp/openmm-metal-bench/ultra-m29-unified/tools/profile-candidate.sh: candidate shader captures to explain overlap and exposed handoff costs.
- /tmp/openmm-metal-bench/ultra-m29-unified/tools/profile-baseline.sh: six frozen-baseline shader captures under a GPU lease.
- /tmp/openmm-metal-bench/ultra-m29-unified/tools/check-candidate.sh: ordered FFT oracle and required correctness checks.
- /tmp/openmm-metal-bench/ultra-m29-unified/tools/smoke.py: benchmark-system smoke probe.
- /tmp/openmm-metal-bench/ultra-m29-unified/tools/smoke-arms.sh: preflight each benchmark arm before timing.
- /tmp/openmm-metal-bench/ultra-m29-unified/tools/screen-candidate.sh: interleaved five-arm timing and ratio summaries.
- /tmp/openmm-metal-bench/ultra-m29-unified/tools/run-m2.sh: serialized remote M2 build/check with recorded verdict.
- /tmp/openmm-metal-bench/ultra-m29-unified/tools/after-screen.sh: resume the validated build after fixing an LJPME diagnostic accessor in the smoke harness.
- /tmp/openmm-metal-bench/ultra-m29-unified/tools/after-ready.sh: detached continuation waiting outside the GPU lease.
- /tmp/openmm-metal-bench/ultra-m29-unified/tools/make-cpu-oracle.py: extract exact CPU transform code for an independent numerical oracle.
- /tmp/openmm-metal-bench/ultra-m29-unified/tools/cpu-oracle.cpp: generated CPU-only DFT and 3D spectrum/roundtrip oracle.
- /tmp/openmm-metal-bench/ultra-m29-unified/tmpl/mst-shader.tracetemplate: shader-timeline-enabled copy of the Xcode template.
- /tmp/openmm-metal-bench/ultra-m29-unified/src/ and build artifacts: verified source snapshot and isolated native build generated by the shared tools.

## Risks and child outcomes

The first two nohup launches did not survive the shell's process group cleanup. The incremental build now uses a setsid-based bg.sh; build.pid and after-ready.pid record the detached processes.

This verdict covers the measured vDSP/Bluestein FFT arm, including its existing PME queue and shared-event handoffs. It is not a lower bound for every possible CPU FFT implementation. CPU bonded and constraints arms were not opened because the FFT arm failed its condition. No shipping changes remain. No commit, push, deployment, or server start occurred.

Strongest suggestion: retain the GPU FFT. Require a new CPU algorithm to demonstrate transform cost below the available nonbonded overlap window before another shared-event integration attempt. The measured vDSP/Bluestein arm cannot earn the keep rule.

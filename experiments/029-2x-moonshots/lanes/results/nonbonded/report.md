# Bet 3: MAX_BITS and nonbonded force accumulation

Verdict after the gate failure: the previous candidate is not cleared for integration. The only repair restores the int028 pair-list policy for single-precision PME. The revised source awaits one more gate run. Both accumulation designs remain rejected.

The revised default sets MAX_BITS to 0 below 100,000 atoms on Apple GPU family 9 or later for non-LJPME mixed systems and non-PME single systems. Common code signals PME and LJPME; mixed PME retains the optimization. M2, large systems, LJPME, and full double retain their old policy. No environment switch or GPU force-storage allocation is added.

The force-accumulation bet is dead in this round. Dense private float slices reach 0.327x int028 on cellulose and 0.182x on STMV. Private tile records retain the original 2400 threadgroups but reach only 0.848x and 0.852x. Neither meets the 1.10x alive threshold. Step (b) was not triggered: the results do not establish a cluster-pair layout that overcomes the storage/reduction cost. No cluster prototype or 2x-across-all-tests result is claimed. The remaining apoa1rf record side screen was cancelled before its lease to stay within the GPU-time budget.

## Gate repair, 2026-09-27

The log `/tmp/openmm-metal-bench/ultra-gate/gate-20260926T232204Z.log` reports:

```text
ctest: 134 tests in 5 parts, 0 failed in the -j2 runs
PASS
pme            23558    single  1.610e-06  8.857e-02  1.340e-06  FAIL max|dF| 8.86e-02 > 2 x base 1.27e-02
```

This repeats the earlier single-PME md100 failure despite intervening passes. The repair removes the changed accumulation order for that method/precision class by restoring the old sparse-pair policy. It is a conservative rollback, not a demonstrated explanation of the numerical intermittency. No PME kernel, tolerance, or test changed. The common hook records PME presence and ORs the LJPME flag across forces, so a later force cannot clear an earlier restriction.

Revised source hash: `052eb211f0d0c4739bbacd08486b4cf06feeda04`, frozen at `/tmp/openmm-metal-bench/ultra-m29-nonbonded-gatefix`. Native build validation is recorded below when complete. No suite, wall, GPU check, or performance screen was rerun for this repair; the gate rerun is still due.

## Performance evidence before gate repair

The tables below describe the pre-repair build. Ultra single rows marked † (pme, apoa1pme, dhfr) no longer measure the revised policy; their gains are withdrawn. All other specialization decisions, including every M2 decision, are unchanged, but these are not measurements of the rebuilt repair. No post-repair keep-rule pass is claimed.

Ultra confirmation uses three interleaved 30-second rounds per arm. Every mixed/OpenCL ratio uses OpenCL single as its denominator. All baseline arms use frozen ultra-int028, commit 7484d7bef401f813dc871c1e156578954606d4ea. Tables name the raw ab.sh directories in every row. Apoa1pme and DHFR each had one build-overlapped round; all five arms of each affected round were replaced once, with the originals retained under replaced/. No runs were dropped based on their speed. PME baseline mixed and OpenCL have 13.8% and 8.7% spread; the table retains all three runs and reports medians.

Host clock; confirmed 3x30 s per arm. Ratios use medians. All retained rounds have zero missing results and zero build overlap.

| Test | Precision | Candidate ns/day | / int028 Metal | / int028 OpenCL single | Raw ab.sh outdir |
|---|---|---:|---:|---:|---|
| gbsa | single | 1603.03 | 0.9993 | 1.3756 | ~/code/metal/bench.noindex/ultra-m29-nonbonded/maxbits-confirm-gbsa |
| gbsa | mixed | 1236.36 | 0.9996 | 1.0609 | ~/code/metal/bench.noindex/ultra-m29-nonbonded/maxbits-confirm-gbsa |
| rf | single | 1450.17 | 1.1881 | 2.1896 | ~/code/metal/bench.noindex/ultra-m29-nonbonded/maxbits-confirm-rf |
| rf | mixed | 1181.01 | 1.1529 | 1.7832 | ~/code/metal/bench.noindex/ultra-m29-nonbonded/maxbits-confirm-rf |
| pme | single † | 986.95 | 1.0899 | 1.8966 | ~/code/metal/bench.noindex/ultra-m29-nonbonded/maxbits-confirm-pme |
| pme | mixed | 854.12 | 1.0774 | 1.6413 | ~/code/metal/bench.noindex/ultra-m29-nonbonded/maxbits-confirm-pme |
| apoa1rf | single | 456.80 | 1.1040 | 1.6295 | ~/code/metal/bench.noindex/ultra-m29-nonbonded/maxbits-confirm-apoa1rf |
| apoa1rf | mixed | 384.76 | 1.0808 | 1.3725 | ~/code/metal/bench.noindex/ultra-m29-nonbonded/maxbits-confirm-apoa1rf |
| apoa1pme | single † | 307.47 | 1.0158 | 1.7003 | ~/code/metal/bench.noindex/ultra-m29-nonbonded/maxbits-confirm-apoa1pme |
| apoa1pme | mixed | 272.75 | 1.0164 | 1.5083 | ~/code/metal/bench.noindex/ultra-m29-nonbonded/maxbits-confirm-apoa1pme |
| apoa1ljpme | single | 239.32 | 1.0003 | 1.8757 | ~/code/metal/bench.noindex/ultra-m29-nonbonded/maxbits-confirm-apoa1ljpme |
| apoa1ljpme | mixed | 217.67 | 1.0046 | 1.7060 | ~/code/metal/bench.noindex/ultra-m29-nonbonded/maxbits-confirm-apoa1ljpme |
| amber20-dhfr | single | 1015.88 | 1.0854 | 1.8030 | ~/code/metal/bench.noindex/ultra-m29-nonbonded/maxbits-confirm-amber20-dhfr |
| amber20-dhfr | mixed | 865.97 | 1.0793 | 1.5369 | ~/code/metal/bench.noindex/ultra-m29-nonbonded/maxbits-confirm-amber20-dhfr |
| amber20-cellulose | single | 81.95 | 0.9990 | 1.7109 | ~/code/metal/bench.noindex/ultra-m29-nonbonded/maxbits-confirm-amber20-cellulose |
| amber20-cellulose | mixed | 74.55 | 1.0001 | 1.5564 | ~/code/metal/bench.noindex/ultra-m29-nonbonded/maxbits-confirm-amber20-cellulose |
| amber20-stmv | single | 30.19 | 0.9987 | 1.6305 | ~/code/metal/bench.noindex/ultra-m29-nonbonded/maxbits-confirm-amber20-stmv-single |
| amber20-stmv | mixed | 27.61 | 0.9978 | 1.4914 | ~/code/metal/bench.noindex/ultra-m29-nonbonded/maxbits-confirm-amber20-stmv-mixed; ~/code/metal/bench.noindex/ultra-m29-nonbonded/maxbits-confirm-amber20-stmv-single |


M2 used two paired 15-second rounds for all nine tests, plus the frozen three-round 30-second OpenCL-single denominator. The full selected-policy check passed with ratios 0.9970–1.0057 of int028 Metal and no reported footprint growth. The exact final source additionally passed the full M2 force gate and an RF 2x15-second check, with ratios 1.000044 single and 1.002081 mixed. Its raw data are in m2-final-rf-raw/. Exact M2 verdict:

```text
verdict cand-src-a030a4fe04 7484d7bef401 PASS: gate PASS; slower: none; footprint growth: none; missing: none
```

| Test | Precision | Candidate ns/day | / int028 Metal | / int028 OpenCL single | Raw check directory | OpenCL denominator directory |
|---|---|---:|---:|---:|---|---|
| gbsa | single | 454.17 | 1.0040 | 1.2143 | ~/code/metal/bench.noindex/ultra-m29-nonbonded/m2-selected-raw | ~/code/metal/bench.noindex/ultra-m29-nonbonded/m2-denominator-raw |
| gbsa | mixed | 376.04 | 0.9970 | 1.0054 | ~/code/metal/bench.noindex/ultra-m29-nonbonded/m2-selected-raw | ~/code/metal/bench.noindex/ultra-m29-nonbonded/m2-denominator-raw |
| rf | single | 291.62 | 0.9984 | 1.1525 | ~/code/metal/bench.noindex/ultra-m29-nonbonded/m2-selected-raw | ~/code/metal/bench.noindex/ultra-m29-nonbonded/m2-denominator-raw |
| rf | mixed | 232.21 | 1.0057 | 0.9177 | ~/code/metal/bench.noindex/ultra-m29-nonbonded/m2-selected-raw | ~/code/metal/bench.noindex/ultra-m29-nonbonded/m2-denominator-raw |
| pme | single | 239.63 | 1.0023 | 1.2347 | ~/code/metal/bench.noindex/ultra-m29-nonbonded/m2-selected-raw | ~/code/metal/bench.noindex/ultra-m29-nonbonded/m2-denominator-raw |
| pme | mixed | 196.49 | 1.0029 | 1.0124 | ~/code/metal/bench.noindex/ultra-m29-nonbonded/m2-selected-raw | ~/code/metal/bench.noindex/ultra-m29-nonbonded/m2-denominator-raw |
| apoa1rf | single | 78.70 | 1.0005 | 1.3315 | ~/code/metal/bench.noindex/ultra-m29-nonbonded/m2-selected-raw | ~/code/metal/bench.noindex/ultra-m29-nonbonded/m2-denominator-raw |
| apoa1rf | mixed | 64.12 | 1.0025 | 1.0849 | ~/code/metal/bench.noindex/ultra-m29-nonbonded/m2-selected-raw | ~/code/metal/bench.noindex/ultra-m29-nonbonded/m2-denominator-raw |
| apoa1pme | single | 59.84 | 0.9997 | 1.3020 | ~/code/metal/bench.noindex/ultra-m29-nonbonded/m2-selected-raw | ~/code/metal/bench.noindex/ultra-m29-nonbonded/m2-denominator-raw |
| apoa1pme | mixed | 50.74 | 0.9977 | 1.1040 | ~/code/metal/bench.noindex/ultra-m29-nonbonded/m2-selected-raw | ~/code/metal/bench.noindex/ultra-m29-nonbonded/m2-denominator-raw |
| apoa1ljpme | single | 44.78 | 1.0006 | 1.3185 | ~/code/metal/bench.noindex/ultra-m29-nonbonded/m2-selected-raw | ~/code/metal/bench.noindex/ultra-m29-nonbonded/m2-denominator-raw |
| apoa1ljpme | mixed | 39.51 | 0.9996 | 1.1632 | ~/code/metal/bench.noindex/ultra-m29-nonbonded/m2-selected-raw | ~/code/metal/bench.noindex/ultra-m29-nonbonded/m2-denominator-raw |
| amber20-dhfr | single | 247.24 | 0.9994 | 1.1943 | ~/code/metal/bench.noindex/ultra-m29-nonbonded/m2-selected-raw | ~/code/metal/bench.noindex/ultra-m29-nonbonded/m2-denominator-raw |
| amber20-dhfr | mixed | 201.34 | 0.9999 | 0.9725 | ~/code/metal/bench.noindex/ultra-m29-nonbonded/m2-selected-raw | ~/code/metal/bench.noindex/ultra-m29-nonbonded/m2-denominator-raw |
| amber20-cellulose | single | 13.28 | 1.0008 | 1.2917 | ~/code/metal/bench.noindex/ultra-m29-nonbonded/m2-selected-raw | ~/code/metal/bench.noindex/ultra-m29-nonbonded/m2-denominator-raw |
| amber20-cellulose | mixed | 11.44 | 0.9998 | 1.1130 | ~/code/metal/bench.noindex/ultra-m29-nonbonded/m2-selected-raw | ~/code/metal/bench.noindex/ultra-m29-nonbonded/m2-denominator-raw |
| amber20-stmv | single | 4.59 | 1.0000 | 1.2403 | ~/code/metal/bench.noindex/ultra-m29-nonbonded/m2-selected-raw | ~/code/metal/bench.noindex/ultra-m29-nonbonded/m2-denominator-raw |
| amber20-stmv | mixed | 4.05 | 1.0035 | 1.0947 | ~/code/metal/bench.noindex/ultra-m29-nonbonded/m2-selected-raw | ~/code/metal/bench.noindex/ultra-m29-nonbonded/m2-denominator-raw |


## Pre-repair source and validation

The measured Ultra selected build has source hash eac2e78665e750192febc7c39da33d9aa04c5c9e. The final build has source hash 1b48d296829378ba52e62fe7d0ac4177f9dd2daf, built 2026-09-26T20:35:26Z. They differ only in MetalNonbondedUtilities.cpp: the final condition preserves full double precision. Their single/mixed specialization decisions and buffer layouts are identical. That snapshot predates the gate repair and no longer matches the worktree. candidate-manifest.md identifies all frozen variants.

Final-build gate.sh --quick terminal verdict:

```text
PASS
```

Final forces.py --md 100 and detforces.py wrapper verdicts:

```text
quick_gate_exit=0 validation_exit=0; see final/validation.verdict
md100_exit=0 detforces_exit=0; pme state captured for diagnosis
```

Every row was ok in this earlier run; the later md100 failure supersedes it for acceptance. The final PME single row is:

```text
pme            23558    single  1.351e-06  1.945e-02  1.321e-06  ok
```

Detforces terminal verdict:

```text
PASS
```

Same-context, new-context, and fresh-process force bytes are identical under DeterministicForces for single and mixed. Energies can differ; energy bitwise equality is not the force contract. The earlier three-fresh-process apoa1rf diagnostic also found zero default-force spread in both precisions. Raw final checks: finish-final.out, final-validation.verdict, and ../ultra-m29-nonbonded-final/validation.verdict. The later run passed all 134 ctest tests but failed md100. The revised source still needs the full gate; ctest was not run here.

Native builds serve as the compilation check. git diff --check passed. No commits or pushes were made. The lab was read-only.

## Memory and architectural verdict

Public recommendedMaxWorkingSetSize is 83,494,174,720 bytes on the 60-core M3 Ultra and 5,726,633,984 bytes on the 10-core M2. The selected MAX_BITS change adds no GPU force-storage buffers: 0 bytes, 0% on both chips. Neighbor-list storage retains its existing allocation/resize rules; this is not a claim of zero change in whole-process peak RSS. M2's paired checks report no footprint growth.

| Prototype/system | Extra Ultra force workspace bytes | Share of Ultra recommended working set | Extra M2 bytes/share |
|---|---:|---:|---:|
| Selected MAX_BITS, every test | 0 | 0% | 0 / 0% |
| Dense, apoa1rf/apoa1pme | 834,442,752 | 0.999402% | 0 / 0% |
| Dense, cellulose | 833,625,600 | 0.998424% | 0 / 0% |
| Dense, STMV | 819,535,872 | 0.981549% | 0 / 0% |
| Records, apoa1rf/apoa1pme | 834,967,240 | 1.0000305% | 0 / 0% |
| Records, cellulose | 834,954,400 | 1.0000152% | 0 / 0% |
| Records, STMV | 834,994,720 | 1.0000634% | 0 / 0% |

Dense figures use the public heap-rounded buffer sizing calculation. Record figures sum actual MTLBuffer.allocatedSize queries. The record prototype exceeds the strict 1% cap by approximately 13–53 KB despite its heap estimates fitting. It is not memory-compliant or a merge candidate. Both prototypes allocate zero extra force storage on M2 and use the old deterministic-force path. Raw memory evidence: device-memory-records.json, record-allocated-memory.json, device-memory-m2.json, and device-memory.json (dense calculation).

Dense slices reduce available threadgroups to 85 on cellulose and 32 on STMV at this cap. The tile-record design preserves occupancy and removes force atomics from the pair kernel; a separate per-atom gather performs the final merge. It builds its reverse index on the existing GPU neighbor-list rebuild flag. Live diagnostics confirm that capacity fallback is not responsible for the losses: cellulose uses about 223k tiles against 812k capacity, and STMV 568k against 807k. The normal path keeps the original schedule when storage does not fit. CSR scatter order can vary between rebuilds in the default record path; DeterministicForces explicitly uses the original fixed-point path, as permitted by the liaison.

| Design | Test, single | / int028 Metal | / MAX_BITS-only | / int028 OpenCL single | Raw screen directory |
|---|---|---:|---:|---:|---|
| Dense slices | cellulose | 0.327 | 0.338 | 0.562 | blocks-screen-amber20-cellulose/ |
| Dense slices | STMV | 0.182 | 0.182 | 0.297 | blocks-screen-amber20-stmv/ |
| Dense slices | apoa1rf | 0.253 | 0.228 | 0.372 | blocks-screen-apoa1rf/ |
| Tile records | cellulose | 0.848 | 0.874 | 1.446 | records-screen-amber20-cellulose/ |
| Tile records | STMV | 0.852 | 0.852 | 1.383 | records-screen-amber20-stmv/ |

Record screens have no build overlap and about 0.3–0.4% record-run spread. One dense STMV run overlapped a build, but both rounds agree within 0.1%; the clean first round already establishes the large loss. The sampled cellulose profile is consistent with pair-kernel savings being consumed by gather/index costs: computeNonbonded spans fall from 1722 to 1436 us per force invocation, while gather adds 350 us and index scatter 212 us. These sampled spans overlap and include warm-up/minimization; they are not exact additive hardware timings. The tail analysis has uneven sampling of short kernels and does not establish an upper bound. Host-clock ab.sh results determine the verdict. See records-profile-cellulose/, record-counts.jsonl, and accumulation-decision.md.

## Risks and handoff

The original broad MAX_BITS candidate failed one md100 PME single row: maximum force error 0.06107 against a 0.02534 limit. The exact failing state was not captured. The selected and final builds subsequently passed the unchanged full md100 check, with PME maxima 0.0193931 and 0.01945. At a captured selected-build state, candidate and int028 Reference errors were nearly identical (0.0206064 and 0.0206026), with maximum candidate-minus-int028 force difference 0.000621691. The repeated failure prompted the single-PME rollback above. Its numerical root cause remains unproven; no tolerance or gate rule changed.

The common virtual PME/LJPME signal changes the C++ interface. Integrate with a coordinated rebuild of OpenMM and its platform plugins, as done for the measured builds. The policy is measured on M3 Ultra and M2; the Apple9-or-later query also covers unmeasured newer devices. Double precision keeps the original policy and was not performance-tested here.

Changed source files:

- `platforms/common/include/openmm/common/NonbondedUtilities.h`: add a virtual PME/LJPME signal with a no-op default.
- `platforms/common/src/CommonCalcNonbondedForce.cpp`: send the method signal when PME or LJPME direct space is enabled.
- `platforms/metal/include/MetalNonbondedUtilities.h`: store the PME and LJPME hints and override the signal.
- `platforms/metal/src/MetalNonbondedUtilities.cpp`: choose MAX_BITS 0 from device family, atom count, PME/LJPME state, and precision.

The final source patch is maxbits-final.patch. The initial MAX_BITS probe, dense design, and record design are archived separately; do not merge those prototype patches. Report paths, helpers, and source identities are preserved in the run log, candidate-manifest.md, and the scope list below.

Strongest suggestion: consider only the revised maxbits-final.patch after the entire gate, including md100, passes. Withdraw the three affected Ultra single-PME performance claims. Keep M2, LJPME, and the large-system defaults unchanged. Do not carry either float-workspace prototype forward without a new storage/ownership argument; their measured costs defeat the intended atomics saving.

## Scope extensions

- `platforms/common/include/openmm/common/NonbondedUtilities.h`: add the platform-neutral PME/LJPME signal.
- `platforms/common/src/CommonCalcNonbondedForce.cpp`: send the PME/LJPME signal for direct-space interactions.
- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/build-final.sh`: Build the final precision guard outside GPU leases.
- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/capture-md100.py`: Capture the PME state after the unchanged md100 force evaluation for diagnosis.
- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/check-md-baseline.sh`: Measure the frozen int028 md100 control and original candidate force determinism.
- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/compile-record-counts.py`: Compile the read-only observer against the frozen record candidate headers and libraries.
- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/confirm-selected.sh`: Queue the selected quick gate and three-round performance confirmation.
- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/confirm.sh`: Run all nine single/mixed confirmations with split STMV holds and raw ratio tables.
- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/device-memory.swift`: Query public device limits and compute prototype buffer capacities on each chip.
- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/diagnose-pme.sh`: Compare candidate and int028 forces at one captured PME trajectory state.
- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/finish-final.sh`: Wait for the final build, queue its checks and write a one-line verdict.
- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/force-spread.py`: Measure fresh-process default and deterministic force spread at identical positions.
- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/m2-memory.py`: Run the public memory query on the designated M2 under its lock and lease.
- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/m2-memory.sh`: Load the designated M2 connection environment for the public memory query.
- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/m2-ratio-table.py`: Join M2 paired-check medians with its frozen OpenCL-single denominator.
- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/measure-blocks.sh`: Run the dense prototype gate and three-test screen.
- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/measure-maxbits.sh`: Run the original MAX_BITS gate and all-nine-test screen.
- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/measure-records.sh`: Run the record prototype gate, smoke and large-system screen.
- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/pme-cutoff-diagnostic.py`: Inspect near-cutoff pairs without changing force-gate rules or tolerances.
- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/pme-force-diagnostic.py`: Capture or reevaluate a PME state and separate force-group contributions.
- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/profile-records.sh`: Keep paired sampled Metal captures and their exports inside one timing lease.
- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/ratio-table.py`: Require all expected raw arms and rounds before printing the 18-row table.
- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/ready-waiter.sh`: Wait for the authorized bench readiness and run the original gate and screen.
- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/record-allocated-memory.swift`: Check actual public MTLBuffer allocatedSize against the strict memory cap.
- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/record-counts.cpp`: Read live tile counts through existing C++ accessors without modifying kernels.
- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/record-counts.py`: Collect live tile counts at steps 1 and 100 on the three screened systems.
- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/record-counts.sh`: Lease the live-count and actual-allocation diagnostics.
- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/record-memory.py`: Retrieve benchmark atom/exclusion counts and lease the public device query.
- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/record-screen.sh`: Compare record accumulation with int028, MAX_BITS-only and OpenCL single.
- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/screen.sh`: Run the original MAX_BITS screen arms through ab.sh.
- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/smoke-arms.sh`: Run a force-only single-step check across frozen baseline and candidate arms.
- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/smoke.py`: Check finite forces after one step on a standard system.
- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/step-a-screen.sh`: Compare dense accumulation with int028, MAX_BITS-only and OpenCL single.
- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/summarize-pme-diagnostic.py`: Summarize same-position Reference errors and candidate-minus-int028 forces.
- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/validate-final.sh`: Validate the exact final source with md100, deterministic forces and state capture.
- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/validate-selected.sh`: Run selected md100/determinism checks and capture-state diagnosis.
- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/validate.sh`: Run the original candidate md100 and determinism checks.
- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/profile-tail.py`: Inspect the final 200 force intervals in existing shader traces without another GPU run.
- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/candidate-manifest.md`: Identify immutable dirty-source builds used for evidence.
- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/accumulation-decision.md`: Record architecture results and the conditional cluster decision.
- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/sparse-design.md`: Document the ownership alternative considered before the record prototype.
- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/dense-verdict.md`: Record the dense prototype rejection and raw timing paths.
- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/report-draft.md`: Maintain the report while measurements run.
- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/report.md`: Provide the final report and tables.
- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/helper-manifest.md`: Explain every authored experiment helper.
- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/scope-extensions.md`: List source and authored artifact scope extensions individually.
- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/float-blocks-with-maxbits.patch`: Preserve the reviewed source snapshot for this candidate or rejected prototype.
- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/force-records-with-maxbits.patch`: Preserve the reviewed source snapshot for this candidate or rejected prototype.
- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/maxbits-final.patch`: Preserve the reviewed source snapshot for this candidate or rejected prototype.
- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/maxbits-selected.patch`: Preserve the reviewed source snapshot for this candidate or rejected prototype.
- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/maxbits.patch`: Preserve the reviewed source snapshot for this candidate or rejected prototype.
- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/m2-maxbits-table.md`: Report paired performance ratios and raw result paths.
- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/m2-selected-table.md`: Report paired performance ratios and raw result paths.
- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/maxbits-screen-table.md`: Report paired performance ratios and raw result paths.

Build products, trace exports, and raw benchmark/check outputs are generated evidence; their directories are identified in the report tables and candidate manifest. The lab was not edited.
- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/repair-apoa1pme.sh`: Replace the one build-overlapped confirmation round with all five paired arms, retaining original raw files.
- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/repair-dhfr.sh`: Replace the build-overlapped DHFR round with all five paired arms and preserve the original data.

- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/maxbits-confirm-table.md`: Provide the final 18-row, three-round Ultra confirmation table with raw outdirs.
- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/final-verdict.txt`: Record the concise keep/dead and validation verdict for review.

- `/tmp/openmm-metal-bench/ultra-m29-nonbonded/gatefix-build.out`: Record the compile-only validation of the single-PME policy rollback, outside the GPU lease.


## Review ruling after gate failure

This ruling supersedes the gatefix verdict above. The gate exited 1 on md100 PME single (`/tmp/openmm-metal-bench/ultra-gate/gate-20260926T232204Z.log`). A follow-up `md100-pme` job ran five alternating fresh md100 runs per arm: pinned int028 failed 2 of 5, with max|dF| 0.234 and 0.174; the validated final build passed 5 of 5, with max|dF| 0.0169 to 0.0217 against the unchanged 2.54e-2 limit. The reviewer ruled this a pre-existing pinned-base flake.

The candidate is the restored validated final source, `ultra-m29-nonbonded-final/src`, source ID `1b48d296`, covering four source files. Use `ultra-m29-nonbonded/maxbits-validated.patch`. The abandoned gatefix excluded every PME system and would lose PME +9% and DHFR +8.5% without fixing the base flake. `maxbits-final.patch` contains that abandoned gatefix; `gatefix-abandoned.patch` preserves its copy. No source was edited and no tests or builds were run this turn. The candidate awaits re-gating; tolerance, bitwise DeterministicForces, and keep-rule requirements stand.


## Re-gate failure on validated source

The re-gate failed after 1169 s; log: `/tmp/openmm-metal-bench/ultra-gate/gate-20260926T234545Z.log`. The build recorded source `1b48d296829378ba52e62fe7d0ac4177f9dd2daf`. Initial force checks passed. Ctest reported PASS for 134 tests in five parts after TestMetalMonteCarloAnisotropicBarostatSingle and TestMetalRpmdSingle each passed their first rerun.

The failing check was again md100 PME single: max|dF| `0.0939531134` exceeded the unchanged `0.0254` limit; rel|dF| was `1.58644656e-06`, with zero cutoff pairs. All other displayed md100 rows passed. This is a failure of the validated candidate on the same check covered by the reviewer's pinned-base flake ruling; the earlier five passing candidate runs do not establish that this candidate never flakes. The receipt remains invalid.

The two gate failures recorded md100 PME single max|dF| values of `0.0886` (prior gate) and `0.0940` (this re-gate), against the unchanged `0.0254` limit.

The reviewer answered: "Ruling stands for this round: report-only, no source change, no PME rollback, no builds or tests." The reviewer is running an exact gate-conditions comparison using unmodified forces.py, all six tests in one process, five runs each on int028 and the candidate. If the candidate fails clearly more often than the base, the reviewer will authorize a specific source investigation in a new round. No repair or passing gate is claimed here.

No source or tolerance changes were made and no tests, builds, suite, or wall were run this turn. The candidate remains `maxbits-validated.patch`; the abandoned PME rollback remains rejected. Scope extension this turn: `/tmp/openmm-metal-bench/ultra-m29-nonbonded/report.md` records the new gate evidence and the reviewer's disposition. No child jobs were launched. Integration remains blocked on the reviewer's comparison and gate disposition.

# 020 Mock FAH core on Metal mixed (C1 properties, C2 checkpoint loop)

## Question

Can a Folding@home core drive the Metal platform the way it drives CUDA and OpenCL? That means three things. The Context has to accept the property map a core passes. A work unit has to run from its XML files, write `checkpointState.xml`, and resume from it in a fresh Context. And every state the core checks has to pass FAHBench's state tests against Reference, including a system over 1M atoms, where the absolute 10 kJ/mol energy tolerance is tightest relative to the total.

## Answer

Yes for the four FAHBench-size work units (2,489 to 173,112 atoms) on the M3 Ultra. Every start state and every post-restart checkpoint passed the state tests, with the force RMS at least 100 times under its tolerance and |dPE| under 1 kJ/mol.

STMV (1,067,095 atoms) fails the energy test and passes everything else: |dPE| is 15.5 to 16.5 kJ/mol against the 10 kJ/mol limit, 1.1e-6 of the total. That isn't a Metal defect. OpenCL single on the same GPU misses too (+18.9 kJ/mol, against +20.9 for Metal single), and nonbonded direct space carries almost all of the error on both. FAH's absolute energy tolerance doesn't scale with system size, and a GPU platform that computes pair energies in float crosses it somewhere between nav's 173k atoms and STMV's 1.07M.

Restarts are deterministic but not continuous bit for bit. Two restarted runs from the same checkpoint files agree bit for bit at every checkpoint, on every work unit. A restarted run matches the uninterrupted run at the first checkpoint and then drifts apart, because a fresh Context computes forces that differ in the last bits at identical positions. The OpenCL control on the same machine does the same thing, so this is how OpenMM's GPU platforms behave, and FAH doesn't require it.

C1 (branch `metal-fah-readiness` in the openmm-metal repo) makes Metal accept `DeviceIndex`, `DisablePmeStream` and `DeterministicForces`. Before it, a core's property map fails with "Illegal property name".

## C1: properties

Commits on `metal-fah-readiness`, based on `metal` 361452c5c:

- c1cf7a005 Accept DeviceIndex, DisablePmeStream, and DeterministicForces on Metal
- 8a70205c1 Document the Metal DeviceIndex, DisablePmeStream, and DeterministicForces properties
- d2cff0eeb Report nondeterministic forces when Metal computes PME on the CPU

What Metal does with each property:

- `DeviceIndex`: accepts "0", "", and lists that name only device 0 (for example "0,0", which the shared `TestCheckpoints.h` passes). It always reports "0". Anything else throws `Illegal value for DeviceIndex: 1.  Metal always uses the Mac's one GPU, so the valid values are "0", "", and lists that only contain 0.`
- `DisablePmeStream`: accepts true/false/1/0 in any case. It reports "true", since Metal has no separate PME queue.
- `DeterministicForces`: accepts true/false/1/0 in any case. Metal accumulates forces and PME charges in 64-bit fixed point whatever the setting, so it reports "true". The exception is `UseCpuPme` "true": the CPU PME kernel is created without deterministic charge spreading (CommonCalcNonbondedForce.cpp:427), so it reports "false".

`TestMetalProperties` passes the FAH map (`Precision`, `DisablePmeStream` "1", `DeviceIndex` "0", `DeterministicForces` "true") and checks the reported values. It also checks that `DeviceIndex` "1" and "0,1" throw the error above, that `DisablePmeStream` "Yes" and `DeterministicForces` "2" throw an "Illegal value" error listing the valid values, and that five force evaluations in each of two Contexts are bitwise equal.

CTest, `ctest -R Metal`, M3 Ultra (the owner ruled out GPU runs on the laptop, so the brief's M3 Pro baseline was not rerun):

| Build | Passed | Failed |
| --- | --- | --- |
| c1cf7a005 + 8a70205c1 (`raw/c1-ctest-metal-m3ultra.log`) | 110 of 112 (55 of 56 per precision) | TestMetalLocalEnergyMinimizerSingle, TestMetalLocalEnergyMinimizerMixed: testLargeForces, openmm#5434 (experiment 021) |
| with d2cff0eeb (`raw/c1-followup-ctest-metal-m3ultra.log`) | 108 of 112 | the two above, plus TestMetalMonteCarloAnisotropicBarostatSingle and TestMetalMonteCarloBarostatSingle, both "This test is stochastic and may occasionally fail". Each passed 3 of 3 reruns (`raw/barostat-reruns.out`). The 022 CTest saw MonteCarloAnisotropicBarostat fail once and pass on rerun on the base branch too |

TestMetalProperties and TestMetalCheckpoints passed in both builds, in single and mixed. d2cff0eeb's last edit reflowed one source comment after the Studio build; the code built and tested is otherwise identical.

## C2: method

`mockcore.py <wu-dir> <out-dir> <steps> <interval>` does what a core does with a work unit. It deserializes `system.xml`, `integrator.xml` and `state.xml` (renaming FAHBench's old `stateCheckpoint` root tag to `State`), then creates a Metal Context with the FAH map above and `Precision` "mixed". From the same start it makes four runs:

- uninterrupted: one Context for all steps.
- xml restart: a new Context for every interval, with the system and integrator deserialized again and the state loaded from the `checkpointState.xml` the previous interval wrote. That is how a core resumes.
- xml restart 2: the same again, to separate restart effects from run-to-run nondeterminism.
- binary restart: a new Context for every interval, loaded from the previous interval's `Context.createCheckpoint()`. The first interval starts from `state.xml`.

State tests follow FAHBench's `StateTests.cpp`, run against Reference: RMS over atoms of the difference in force magnitude at most 5 kJ/mol/nm, |dPE| and |dKE| at most 10 kJ/mol, and no NaNs. They run at the start state and at every xml-restart checkpoint. The checkpoints also get FAHBench's final-state sanity limits: no velocity component over 17.47 nm/ps, at most half the velocity components exactly zero, and no force component over 50000 kJ/mol/nm. The start state skips those, as in FAHBench. dhfr-implicit's work unit ships with every velocity zero, so it could never pass them. RMS and maximum vector force errors are reported too, since they are stricter than FAHBench's magnitude RMS.

Continuity compares positions and velocities bit for bit at every checkpoint. At each uninterrupted checkpoint the harness also loads the Context's binary checkpoint into a fresh Context and compares the two Contexts' forces. The positions are identical and only the history differs.

`makewu.py` writes work units for the systems FAHBench lacks. `stmv` builds Amber20 STMV as OpenMM's benchmark.py does (PME, 0.9 nm cutoff, HBonds). `tip4pew` is a 5 nm TIP4P-Ew water box, minimized on the CPU platform, because `addSolvent` leaves clashes at the box faces that put a 121k kJ/mol/nm force into the first unminimized attempt. Both get LangevinMiddleIntegrator at 2 fs and MonteCarloBarostat(1 bar, 300 K, every 25 steps), with fixed seeds (2026) as FAH's nav work unit has. With seed 0 the barostat picks a new random seed in every Context, so the first tip4pew attempt's restarted runs could not be compared.

Work units:

| WU | Atoms | Integrator | Forces | Steps / interval |
| --- | ---: | --- | --- | --- |
| dhfr-implicit | 2,489 | Verlet 2 fs | GBSAOBC, CutoffNonPeriodic 2 nm | 2000 / 500 |
| dhfr | 23,558 | Verlet 2 fs | PME 0.8 nm | 2000 / 500 |
| tip4pew | 16,264 | LangevinMiddle 2 fs, barostat | PME 0.9 nm, virtual sites | 2000 / 500 |
| nav | 173,112 | Langevin 2 fs, barostat | PME 1.0 nm | 1000 / 250 |
| stmv | 1,067,095 | LangevinMiddle 2 fs, barostat | PME 0.9 nm | 200 / 100 |

nav's `integrator.xml` says `LangevinIntegrator`, but the JSON reports `LangevinMiddleIntegrator`. The C++ deserializer does create a LangevinIntegrator (serialization/src/LangevinIntegratorProxy.cpp:54). In this OpenMM that class is a subclass of LangevinMiddleIntegrator that adds nothing (openmmapi/include/openmm/LangevinIntegrator.h:45), and the Python wrapper hands it back as the base class. The dynamics are the same either way.

Machine: Mac Studio M3 Ultra, macOS 27.2 26B5091g, under `/tmp/openmm-metal-bench/020`, with its own OpenMM build of `metal-fah-readiness` in a private venv (python 3.13). Every run held the shared machine lease.

## C2: results

State tests (kJ/mol/nm and kJ/mol; FAH limits: force RMS 5, dPE and dKE 10):

| WU | atoms | integrator | state | force RMS (FAH) | max vector force error | dPE | dKE | max abs v | max abs F | pass |
| --- | ---: | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| dhfr-implicit | 2,489 | VerletIntegrator | start | 0.0098 | 0.098 | 0.015 | 4.5e-05 | 0.00 | 2637 | yes |
|  | |  | step 500 | 0.0102 | 0.131 | 0.011 | 6.8e-06 | 3.48 | 1612 | yes |
|  | |  | step 1000 | 0.0101 | 0.093 | 0.012 | 1.2e-05 | 2.99 | 1533 | yes |
|  | |  | step 1500 | 0.0097 | 0.115 | 0.012 | 0.00015 | 2.53 | 1794 | yes |
|  | |  | step 2000 | 0.0095 | 0.111 | 0.012 | 6e-05 | 2.63 | 1512 | yes |
| dhfr | 23,558 | VerletIntegrator | start | 0.0008 | 0.020 | 0.697 | 2.7e-05 | 4.77 | 2719 | yes |
|  | |  | step 500 | 0.0058 | 0.112 | 0.706 | 0.00086 | 4.48 | 2759 | yes |
|  | |  | step 1000 | 0.0057 | 0.120 | 0.687 | 0.0005 | 4.86 | 2894 | yes |
|  | |  | step 1500 | 0.0063 | 0.243 | 0.665 | 0.00011 | 4.65 | 2981 | yes |
|  | |  | step 2000 | 0.0060 | 0.243 | 0.725 | 0.00074 | 4.83 | 2779 | yes |
| tip4pew | 16,264 | LangevinMiddleIntegrator | start | 0.0034 | 0.027 | 0.157 | 9.8e-11 | 5.27 | 2527 | yes |
|  | |  | step 500 | 0.0040 | 0.299 | 0.181 | 3.3e-11 | 5.48 | 3293 | yes |
|  | |  | step 1000 | 0.0052 | 0.607 | 0.221 | 6.2e-11 | 5.45 | 3441 | yes |
|  | |  | step 1500 | 0.0020 | 0.021 | 0.209 | 9.8e-11 | 5.64 | 3023 | yes |
|  | |  | step 2000 | 0.0020 | 0.019 | 0.194 | 3.3e-11 | 5.59 | 2986 | yes |
| nav | 173,112 | LangevinMiddleIntegrator | start | 0.0012 | 0.077 | 0.759 | 1e-08 | 7.03 | 5431 | yes |
|  | |  | step 250 | 0.0396 | 0.712 | 0.627 | 2.9e-10 | 6.57 | 6429 | yes |
|  | |  | step 500 | 0.0391 | 0.815 | 0.696 | 2.9e-09 | 7.01 | 5041 | yes |
|  | |  | step 750 | 0.0393 | 0.710 | 0.766 | 2.4e-09 | 6.96 | 5907 | yes |
|  | |  | step 1000 | 0.0393 | 0.956 | 0.613 | 1.4e-08 | 7.24 | 5800 | yes |
| stmv | 1,067,095 | LangevinMiddleIntegrator | start | 0.0665 | 1.567 | 15.468 | 6.7e-08 | 7.16 | 6600 | NO |
|  | |  | step 100 | 0.0651 | 1.525 | 15.859 | 1.2e-07 | 7.38 | 6104 | NO |
|  | |  | step 200 | 0.0647 | 1.530 | 16.549 | 8.6e-08 | 7.03 | 6743 | NO |

Continuity. Max |dpos| in nm at each checkpoint, or "bitwise":

| WU | steps / interval | repeat forces | repeat energy diff | xml restart vs uninterrupted, max dpos nm per checkpoint | xml restart vs xml restart | binary restart vs uninterrupted | fresh Context forces bitwise |
| --- | --- | --- | ---: | --- | --- | --- | --- |
| dhfr-implicit | 2000 / 500 | bitwise | 7e-12 | 0 (bitwise), 0.0088, 0.21, 0.47 | bitwise at all 4 | 0 (bitwise), 0.0089, 0.21, 0.35 | 0 of 4 (max diff 0.00065) |
| dhfr | 2000 / 500 | bitwise | 7e-10 | 0 (bitwise), 0.03, 0.45, 0.53 | bitwise at all 4 | 0 (bitwise), 0.02, 0.32, 0.49 | 1 of 4 (max diff 0.0055) |
| tip4pew | 2000 / 500 | bitwise | 5e-10 | 0 (bitwise), 0.49, 0.65, 0.73 | bitwise at all 4 | 0 (bitwise), 0.33, 0.77, 0.89 | 0 of 4 (max diff 0.0021) |
| nav | 1000 / 250 | bitwise | 3e-09 | 0 (bitwise), 0.54, 0.74, 0.84 | bitwise at all 4 | 0 (bitwise), 0.011, 0.25, 0.53 | 0 of 4 (max diff 0.025) |
| stmv | 200 / 100 | bitwise | 2e-08 | 0 (bitwise), 0.34 | bitwise at all 2 | 0 (bitwise), 0.00015 | 0 of 2 (max diff 0.088) |

What the continuity table shows:

- Repeat force evaluations from the same state in two new Contexts are bitwise equal on every work unit. Energies differ by 7e-12 to 2e-8 kJ/mol, because they are summed in floating point. FAH compares them with a 10 kJ/mol tolerance.
- Two xml-restarted runs are bitwise equal at every checkpoint, so Metal mixed is deterministic for a given history, barostat included, once the seeds are fixed.
- Restarted runs match the uninterrupted run at the first checkpoint, where both are a fresh Context started from `state.xml`. After that they drift apart. The cause is the fresh-Context force check: at bitwise identical positions, a Context that has run for a while and one just loaded from its checkpoint give forces that differ in the last bits (max 6.5e-4 to 8.8e-2 kJ/mol/nm, on almost every atom). With a cutoff, the Context reorders atoms every 250 steps and rebuilds its neighbor list as atoms move. Two histories therefore sum the same pair terms in a different float order before the fixed-point accumulation. Chaotic dynamics grows that to tenths of a nm within 1000 steps of the restart. Once in a while the layouts line up and the forces are bitwise (dhfr at step 1000).
- Langevin xml restarts drift faster than binary ones (nav 0.54 against 0.011 nm at the second checkpoint). `checkpointState.xml` carries no random number state, so every resumed interval starts the integrator's noise from the seed again. The binary checkpoint carries it.

OpenCL control (`raw/control.jsonl`, dhfr, 1000 / 250, binary restart): OpenCL single on the same M3 Ultra also gets non-bitwise forces in a fresh Context at identical positions (14k to 19k atoms differ, max 0.0095). Its restarted run also drifts from the uninterrupted one (0 at the first checkpoint, then 0.0017, 0.031, 0.28 nm), so this is how the GPU platforms behave and not a Metal defect. Metal single and mixed drift the same way in that run. Their fresh-Context forces were bitwise at 2 of 4 and 1 of 4 checkpoints, OpenCL's at none.

FAH does not require bitwise continuation across a restart. It requires that the resumed state pass the state tests. Every resumed state passed on the four FAHBench-size work units. STMV's resumed states failed only the energy test, as its start state did.

### STMV and the 10 kJ/mol energy limit

STMV fails the energy test at the start state and at both checkpoints (15.47, 15.86, 16.55 kJ/mol), with Metal's energy higher each time. Every other check passes. To find which term carries the error, `decompose.py` puts each force in its own force group and NonbondedForce's reciprocal space in another, then compares every group with Reference at the start state. OpenCL came from the shared env's build of the `metal` branch at f9347f6c5, used read-only; the 020 build has OpenCL off.

Platform minus Reference, kJ/mol (`raw/decompose.out`, `raw/decompose-opencl.out`):

| System | Platform | Bond | Angle | Torsion | Nonbonded direct | Nonbonded reciprocal | Total |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| STMV (Reference total -14,039,345.9) | Metal mixed | -0.035 | -0.150 | -0.073 | +14.98 | +0.74 | +15.47 |
| | Metal single | -0.034 | -0.148 | -0.070 | +19.70 | +0.73 | +20.85 |
| | OpenCL single | -0.025 | -0.148 | -0.070 | +18.20 | +0.74 | +18.92 |
| | CPU | 0.000 | 0.000 | 0.000 | -3.56 | -0.80 | -4.36 |
| nav (Reference total -1,720,827.8) | Metal mixed | -0.017 | -0.036 | -0.016 | +0.68 | +0.15 | +0.76 |
| | Metal single | -0.017 | -0.035 | -0.015 | +0.69 | +0.15 | +0.76 |
| | CPU | 0.000 | 0.000 | 0.000 | -0.20 | -0.12 | -0.32 |

- Metal mixed's total, +15.47, equals mockcore's start-state dPE, so the split accounts for all of it.
- OpenCL mixed does not exist on this GPU: creating the Context fails with "No compatible OpenCL platform is available". Apple's OpenCL has no double precision, so single is the only OpenCL precision FAH could run here. Metal single against OpenCL single is the like-for-like pair: +20.9 against +18.9, same sign, both carried by direct space. Their direct-space energies differ by exactly 1.5 kJ/mol, so I would not read anything into the gap between them.
- Mixed precision helps a little (+15.0 against +19.7 in direct space) because it accumulates the energy in double. The pair terms are still computed in float.
- The CPU platform passes at -4.4.

What the split shows is where the error lives: GPU direct space, on both GPU platforms, with the same sign. It does not show the mechanism. A constant bias per pair does not fit. STMV's 15 kJ/mol over about 1.7e8 pairs is 9e-8 per pair, which would predict 2.5 to 3.5 kJ/mol for nav with its 1.0 nm cutoff, and nav measures 0.68. The likely suspects are float arithmetic in the shared nonbonded kernel source (`erfc`, `exp`, the per-pair sums), but that is unproven. Since OpenCL shows the same thing, I did not chase it into the kernel. For FAH, the question is whether projects this large get a size-scaled energy tolerance, or run their state tests on a platform that passes.

Wall time, seconds, host wall clock (`time.perf_counter`), owner at the keyboard, light CPU. Each figure includes Context creation and kernel compilation for every new Context, and the uninterrupted figure includes the fresh-Context force checks, so these are not throughput numbers:

| WU | uninterrupted | xml restart + state tests | xml restart | binary restart | Reference, slowest checkpoint test |
| --- | ---: | ---: | ---: | ---: | ---: |
| dhfr-implicit | 0.8 | 1.7 | 1.2 | 0.8 | 0.1 |
| dhfr | 10.2 | 16.5 | 10.1 | 8.8 | 1.6 |
| tip4pew | 1.9 | 3.8 | 2.7 | 1.9 | 0.3 |
| nav | 7.1 | 37.7 | 22.2 | 6.7 | 3.9 |
| stmv | 12.8 | 89.2 | 42.0 | 10.6 | 23.4 |

## Files

- `mockcore.py`: the harness.
- `makewu.py`: builds the stmv and tip4pew work units.
- `control.py`: the restart continuity check on any platform and precision, for the OpenCL control.
- `decompose.py`: the per-force-group energy split against Reference.
- `lane/`: the Studio drivers. `build.sh` builds the branch with OpenCL off and installs it into a private prefix and venv. It takes cmake and ninja from the shared env's bin and installs nothing there. `ctest.sh` runs `ctest -R Metal`, and `rebuild-test.sh` rebuilds after a source sync and runs it again. `c2.sh` runs mockcore over the work units, and `control.sh`, `baro.sh`, `decompose.sh` and `decompose-ocl.sh` run the other checks. Each takes the shared lease around its GPU work.
- `raw/results.jsonl`: one JSON line per work unit from `mockcore.py`. The per-WU `result.json` files have the same content.
- `raw/run.log`, `raw/makewu.log`: stderr and start/exit times of the C2 driver. The first stmv attempt failed because experiment 018's Amber inputs had been removed from the Studio. The inputs were copied into 020 and stmv was rerun.
- `raw/control.jsonl`, `raw/control.log`: the OpenCL and Metal control.
- `raw/run1-results.jsonl`, `raw/run1-run.log`: the first C2 run, which applied the sanity limits to the start state too, with an unminimized tip4pew whose barostat had seed 0. Its dhfr-implicit and tip4pew start states failed the sanity limits (all velocities zero, and a 121,322 kJ/mol/nm force). Every checkpoint passed, and tip4pew's two xml-restarted runs were not bitwise equal. The run was stopped during nav.
- `raw/c1-ctest-metal-m3ultra.log`, `raw/c1-rebuild-test-m3ultra.out`: C1 CTest before d2cff0eeb. The `.out` file ends with three reruns each of TestMetalBrownianIntegratorMixed and TestMetalNoseHooverIntegratorSingle, run by hand to check two tests with a history of one-off failures. All six passed.
- `raw/c1-followup-ctest-metal-m3ultra.log`, `raw/c1-followup-rebuild-test-m3ultra.out`, `raw/barostat-reruns.out`: C1 CTest with d2cff0eeb, and the barostat reruns.
- `raw/decompose.out`, `raw/decompose-opencl.out`: the energy split for STMV and nav, one JSON line per platform between the driver's start and exit lines. The OpenCL file ends with the OpenCL mixed traceback.

The `checkpointState.xml` files were not kept. nav's is 28 MB and STMV's is 176 MB, and the harness regenerates them.

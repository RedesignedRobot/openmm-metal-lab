# What a Folding@home OpenMM core needs from a Metal platform

Date: 2026-09-23. Read-only research from public sources: foldingforum (forum.foldingathome.org), FoldingAtHome and openmm GitHub, the public FAHBench source, Chodera-lab and OpenFE tooling that writes FAH work units, conda-forge, and the live `api.foldingathome.org/gpus`. Nothing was posted, nothing ran on the laptop. Tiers: **[V]** I read the source or doc, **[R]** a source says so, **[I]** my inference. Client-side detection is covered in depth in the sibling report `2026-09-23-fah-client-apple-gpu.md`.

## Summary

1. Ranked checklist: (a) Metal in a released OpenMM, since FAH doesn't use betas and builds cores from conda-forge packages; (b) Metal in the conda-forge osx-arm64 `openmm` package; (c) a public validation pack that runs FAH's own state tests on FAH-format WUs; (d) Metal accepts the same property names as HIP (`DeviceIndex`, `Precision`, `DisablePmeStream`, `DeterministicForces`, `UseBlockingSync`); (e) a client PR that follows jcoffland's non-PCI plan; (f) ns/day on FAH benchmark projects for each chip, so they can set species; (g) a short "integration diff" note showing the core change is a new `-gpu-platform` branch.
2. Core lineage [V/R]: core22 (OpenMM 7.2 to 7.7, OpenCL from 2019-03-14, CUDA from 0.0.13 on 2020-09-28), core23 (OpenMM 8.0.0, 2023-08-26), core24 (8.1.1), core26 (8.2.0, built 2025-01-07), core27 (8.2.x, 2025-03), core28 (8.3.1, first with HIP, announced 2026-03-28). Every GPU core so far is Windows and Linux only.
3. HIP is the precedent, and it was slow. OpenMM merged HIP on 2024-08-28 and shipped it in 8.2.0 on 2024-11-08; FAH's core28 took until 2026-03 to announce and 2026-09 to get projects into full FAH. It had AMD engineers and Peter Eastman helping. FAH's gate, per Joe_H: validation that it "gives same results as OpenCL or CUDA", then packaging.
4. Checks [V/R]: FAH's state tests match FAHBench's `StateTests.cpp`: NaN checks, a velocity cap of 17.47 nm/ps, a force cap of 50,000 kJ/mol/nm, force-magnitude RMSE ≤ 5 kJ/mol/nm, and |ΔE| ≤ 10 kJ/mol (live logs show 20) against a CPU reference. They run at start and at every checkpoint (default every 5%). A failure means "Bad State", 2 retries from the last checkpoint, then the WU dies.
5. Precision [V/R]: the core has a `precision` option (single, mixed or double; documented default single), and projects choose it. Chodera-lab tooling writes `mixed`, core22 launched as mixed, and staff say every GPU core needs FP64. The binding gate is the GPU whitelist: 16 Intel DG2 rows are species 0 and labelled "-no FP64 support". The reason given is that Intel's driver FP64 emulation "gave inconsistent results, or caused the folding core to crash".
6. Can df64 mixed without fp64 hardware pass? [I] Yes on the checks: they compare results against the reference within tolerances and never probe hardware. The hard case is the absolute 10 kJ/mol energy limit on multi-million-atom systems, so measure that. The real obstacle is policy. Beat it with evidence that df64 isn't the Intel failure mode.
7. Does FAH ever run single? [R] The core can: the option exists, and Chodera wrote in 2022 that "even single precision only can be useful for some of our workloads". I found no public evidence of a live single-precision project, and the whitelist blocks non-FP64 GPUs for every project.
8. Build and distribution [V/R]: the client runs only cores that carry an FAH signature with key usage `core%02x` (`Core.cpp:133-135`). Cores come from AS-supplied URLs. The a8 CPU core runs natively on Apple silicon. No macOS GPU core has ever shipped. Species is a u16 per PCI vendor/device in gpus.json, and projects filter on species constraints.
9. Who decides [R]: Greg Bowman (director), Vincent Voelz and John Chodera "direct what [Joseph] spends time on". Cores come from the GPU FAHCore team (named: Hugo, Sukrit, Ben, Justin). jcoffland owns the client, AS and DB. His public position is that non-PCI GPU support "is a priority" (2026-01-28). muziqaz, a tester, said on 2025-11-14 that there will not be a new core for Apple GPUs.
10. Unverified: the closed core's source, its exact property list and platform-selection code, whether its reference is the CPU or Reference platform, the AS constraint syntax, and whether any single-precision project is live.

## 1. What each OpenMM core runs, and how platforms were added

| Core | Version | OpenMM | Platforms | OS | Date | Source |
|---|---|---|---|---|---|---|
| 21 | 0.0.x | 6.2 | OpenCL | Win, Linux | 2015 | [R] Wikipedia list; FAH fork branch `core21` has Eastman's "Changes required for core21", 2015-06-22 [V] |
| 22 | 0.0.1 to 0.0.20 | 7.2, later 7.4.x, 7.5.x, 7.6.0, 7.7.0 | OpenCL at launch; CUDA from 0.0.13 | Win, Linux | launch 2019-03-14; CUDA 2020-09-28 | [R] rafwiewiora's announcement ("based on OpenMM 7.2 ... OpenCL version first, with CUDA joining in one of the next few versions", "Precision: Mixed"); FAH CUDA blog, 2020-09-28 (search snippet; the page now 404s); fork branches `core22-openmm-7.4.1/7.4.2/7.5.0` [V] |
| 23 | 8.0.3 | 8.0.0 | OpenCL, CUDA | Win, Linux | 2023-08-26 | [R] hmacdope's announcement |
| 24 | 8.1.3, 8.1.4 | 8.1.1 | OpenCL, CUDA | Win, Linux | 8.1.4 reported 2024-07-25 | [R] forum logs ("Version: 8.1.4 ... OpenMM Version: 8.1.1"); needs glibc 2.33/2.34 on Linux |
| 25 | none | | | | never released | [R] Wikipedia |
| 26 | 8.2.0 | 8.2.0 | OpenCL, CUDA | Win, Linux | built 2025-01-07 | [R] log "Date: Jan 7 2025 ... OpenMM Version: 8.2.0", GNU 7.5.0; muziqaz 2025-01-17: target was "core errors and possibility to do more variations of science" |
| 27 | 8.2.1 | 8.2.x | OpenCL, CUDA | Win, Linux | dated 2025-03-27 (reported) | [R] muziqaz 2025-05-09: "Core27 was thought to have HIP. But it was pushed without hip" |
| 28 | 8.3, 8.3.1 | 8.3.1 | OpenCL, CUDA, HIP (ROCm 6.4.4 only) | Win, Linux | announced 2026-03-28; in full FAH by 2026-09-12 | [R] muziqaz's announcement; Wikipedia rows; forum page 3 |

How platforms were added before:

- **OpenCL first, CUDA later (core22).** The CUDA platform had been in OpenMM for years. FAH still shipped core22 as OpenCL-only in 2019 and added CUDA 18 months later in 0.0.13. The blocker was shipping the CUDA runtime and compiler libraries: the blog says 0.0.13 "automatically downloaded the CUDA-enabled version of the core and CUDA runtime compiler libraries" [R]. Lesson [I]: packaging, not the platform code, set the pace.
- **HIP (core28), the closest precedent.**
  - 2022-10/11: AMD and StreamHPC maintain an out-of-tree plugin (`amd/openmm-hip` created 2022-10-26; `StreamHPC/openmm-hip` created 2022-11-18, now archived with "the HIP platform is a part of OpenMM now") [V].
  - 2024-08-28: openmm#4632 "HIP platform" by ex-rzr (Anton Gorenko) merged [V]. OpenMM 8.2.0 ships it on 2024-11-08; the release notes thank Anton Gorenko and say HIP can't go through conda-forge, so it ships via pip [V].
  - 2024-11-06: muziqaz says FAH's GPU priority is "sort out few issues with PC side and get AMD HIP out. After that it is possible we can ask to look into Apple GPU stuff" (fah-client-bastet#303) [V].
  - 2025-05-02: Joe_H: "A core has to be built, go through validation testing to show whether HIP gives same results as OpenCL or CUDA. Then figure out packaging with necessary libraries." toTOW, 2025-05-09: "FAH doesn't integrate beta version of OpenMM" [R].
  - 2025-12-25: the 8.5 client already has HIP options. Joe_H says the core is "still something in the planning stages" [R].
  - 2026-03-28: muziqaz announces core28 after "over 2 years", crediting "Hugo, Sukrit, Ben, and Justin (GPU FAHCore team), Joseph (F@H lead developer), Peter Eastman (OpenMM), AMD" [R].
  - 2026-08-14: the rebuilt core is "with the main dev for validation" before internal testing. On 2026-09-12 a volunteer runs core28 8.3.1 with HIP, and muziqaz says the project "is in full fah" [R].
  - Driver [I]: AMD wrote the platform, OpenMM upstreamed it, and FAH's small core team did validation and packaging. Upstream release to live projects took about 22 months.
- **ARM64 CPU (a8).** External partners drove the port in 2020 ("Neocortix, Linaro, Arm, miniNodes, and Packet.com") [R, CNX Software 2020-08-14]. Chodera wrote on 2020-12-14: "We've been working on building Folding@home cores for the ARM architecture used in the new M1 chip!" [R]. Precedent [I]: FAH accepts ports that outsiders do most of.

## 2. The checks a core applies, and precision

**State tests.** FAHBench is FAH's public GPU benchmark (FoldingAtHome/fah-bench, a fork of fahbench/fahbench). Its `StateTests.cpp` was written by Yutong Zhao, who also wrote the early cores, and I read it [V]:

- `checkForNans`: NaN in positions, velocities or forces.
- `checkForDiscrepancies`: any |v| > 17.47 nm/ps ("Velocities are blowing up"), more than half of the velocity components exactly 0, or any |F| > 50,000 kJ/mol/nm ("Forces are blowing up").
- `compareForces`: RMS over atoms of (|F_ref| − |F_test|), compared with `DEFAULT_FORCE_TOL_KJ_PER_MOL_PER_NM = 5`. Only magnitudes are compared, not directions.
- `compareEnergies`: absolute |ΔPE| and |ΔKE|, compared with `DEFAULT_ENERGY_TOL_KJ_PER_MOL = 10.0`.
- FAHBench runs these against the **Reference** platform at start (`Simulation.cpp:104-113`) and defaults to `precision("single")` (`Simulation.cpp:30`).

The live core prints the same strings, so it uses this code or a close descendant [I, strong]:

- "Force RMSE error of 6.1443 with threshold of 5" (core 0x22, 2021-03-07) [R].
- "Potential energy error of 296.63, threshold of 20 / Reference potential energy: -1.94858e+06 | Given potential energy: -1.94887e+06" (core 0x24, OpenMM 8.1.1) [R].
- "Potential energy error of 516.952, threshold of 20 / Reference Potential Energy: -4.16034e+06 | Given ..." followed by "ERROR:98: Attempting to restart from last good checkpoint by restarting core" (fah-web-client-bastet#167, 2024-07-24) [V].
- "Bad State detected... attempting to resume from last good checkpoint. Is your system overclocked? Following exception occured: Force RMSE error of 5.23885 with threshold of 5", then "ERROR:114: Max Retries Reached" (2020-03-16) [R].

**Per-project knobs in `core.xml`.** From OpenFE's alchemiscale-fah `FahOpenMMCoreSettings`, last changed 2026-02-04 [V as their documentation, R as core behavior]:

- `checkpointFreq` default −5, meaning every 5%.
- `maxRetriesFromLastCheckpoint` default 2.
- `precision`: "Specify the OpenMM OpenCL platform precision [mixed, single, double] (optional, default: single)".
- `forceTolerance` 5 kJ/mol/nm and `energyTolerance` 10 kJ/mol, both "for triggering Bad State errors".
- `DisablePmeStream` default 1, "setting 0 may cause failures on some cards".
- `disableCheckpointStateTests` default 0, so state tests run at every checkpoint.
- `minimize` 0/1.

perses cites the core's README as `github.com/foldingathome/openmm-core`, which is private [V]. The work server sends `core.xml`, `system.xml.bz2`, `integrator.xml.bz2` and `state.xml.bz2` for core 0x26 (alchemiscale-fah `docs/deployment.rst`) [V].

**Checkpoint semantics.** Joe_H, 2022-11-16: GPU checkpoints "are set by the researcher", and at each one "a sanity check is done on the data ... on the CPU to verify the GPU is properly calculating". toTOW, 2022-11-23: the OpenMM core "doesn't support triggered checkpoints", and it "performs checks ... between data computed on the GPU and data computed on the CPU before it writes a checkpoint". Joe_H, 2024-02-23: the client's checkpoint setting doesn't apply to GPU WUs, and the frequency is "usually between 2% and 5%" [R].

**Properties.** FAH cores "unconditionally set `DisablePmeStream`" (arisu3, openmm#5008, 2025-07-10). Eastman replied: "Using the separate stream works fine ... I'm not sure why FAH disables it." [V as statements]. perses' FAH setup sets `Precision=mixed` for CUDA and OpenCL, and `DeterministicForces=true` for CUDA only (`fah_generator.py:206-210`) [V]. FAH forked OpenMM with a `force-pmequeue-false` branch (Chodera, 2015-11-19: "eliminate race condition on NVIDIA") and a NaN-detection backport [V]. Upstream property sets [V, local tree]:

| Platform | Properties |
|---|---|
| OpenCL | DeviceIndex, DeviceName, DisablePmeStream, OpenCLPlatformIndex, OpenCLPlatformName, Precision, UseCpuPme |
| HIP | DeterministicForces, DeviceIndex, DeviceName, DisablePmeStream, Precision, TempDirectory, UseBlockingSync, UseCpuPme |
| CUDA | HIP's set plus CudaCompiler, CudaHostCompiler |
| Metal, branch `metal` | DeviceName, Precision, UseCpuPme, TempDirectory (C1 adds more) |

**Precision in practice.**

- rafwiewiora, core22 launch, 2019-03-14: "Precision: Mixed" for p11733 [R].
- fah-xchem writes `<precision>mixed</precision>` into core.xml [V], and so do the perses defaults [V].
- Joe_H, 2024-07-13: "FP64 support is required. The current GPU folding cores use some double precision calculations where needed to maintain sufficient numerical accuracy." On 2025-12-17 he said clinfo shows no FP64 on M-series, "which all current GPU cores require" [R].
- Live gpus.json, fetched today [V]: 16 Intel DG2 rows have species 0 and descriptions like "DG2 [Arc A770] -no FP64 support". Xe-LP (Alder Lake Iris Xe) is species 0 too. Battlemage and Arc 140V are species 2 to 3; muziqaz whitelisted them on 2024-12-14 [R].
- The Arc precedent. Joe_H, 2022-10-04: Arc uses driver FP64 emulation, and "Tests done using folding gave inconsistent results, or caused the folding core to crash". toTOW, 2022-10-03: "The software implementation of double precision is not reliable enough yet to run FAH" [R].
- OpenMM's OpenCL platform refuses mixed without `cl_khr_fp64` (`OpenCLContext.cpp:214-216`, "This device does not support double precision") [V]. That is why the Apple OpenCL path can't be mixed.

**Could Metal df64 mixed pass?** [I]

- Nothing in the tests checks for FP64 hardware. They compare results against a CPU reference.
- Force RMSE ≤ 5 kJ/mol/nm is loose. On the M2, OpenCL *single* already agrees with Reference to about 1e-6 relative (lab experiment 014).
- The tight test is the absolute energy limit of 10 kJ/mol (20 seen live). On a 2-to-4-million kJ/mol system, 20 kJ/mol is 5e-6 to 1e-5 relative. CUDA mixed already fails it now and then (the 296 and 517 kJ/mol failures above).
- Energy accumulation must be at least double-like, which our df64 accumulation gives. But the direct-space erfc approximation and PME settings, not accumulation, may dominate at scale. Measure |ΔE| in kJ/mol against Reference or CPU on 1M to 8M atom systems. core28's first HIP project had 7.9M atoms (forum page 2).
- The case to make: df64 is deterministic arithmetic in our own kernels, not driver emulation. Show it gives CUDA-mixed-equivalent results and never crashes, because that is exactly where Arc failed.

**Single precision.** Chodera, openmm#2489, 2022-10-20: "Even single precision only can be useful for some of our workloads in supporting antiviral discovery!" He also asked Eastman: "Does this mean we could not use OpenMM in mixed precision on osx with OpenCL?" [V]. The documented default in core.xml is single [R]. So a single-precision FAH project is possible in principle. I found no public evidence that one runs today, and the whitelist excludes non-FP64 GPUs before any project could choose [V/I].

## 3. Build, sign, distribute; macOS arm64; species

- **Signing** [V]: the client downloads `<url>.crt`, `<url>.sig` and the package. It checks the SHA-256 against the AS-provided hash and calls `app.check(cert, "", sig, hash, "core|core%02x")` (`fah-client-bastet/src/fah/client/Core.cpp:76-78,128-136`). The package must be a (compressed) tar. Only FAH's key can make a core that clients will run.
- **Arch** [V]: the client reports `os`, `os_version`, and `cpu` = `arm64` on aarch64, otherwise `amd64`/`x86` (`OS.cpp:72-78`, `App.cpp:429-431`). The AS picks the core per OS and arch. Open PR fah-client-bastet#442 (2026-05-04, still a draft per jcoffland) generalizes Linux aarch64 and HIP platform selection [V].
- **Core CLI** [V]: the client passes `-gpu-platform cuda|opencl` only, plus `-gpu-vendor`, `-opencl-platform/-device`, `-cuda-*`, `-hip-*`, `-gpu <opencl device>` and `-gpu-uuid` (`Unit.cpp:639-667`). Any Metal selection is either a new flag value or core-side logic.
- **Build environments** [V/R]: the public `docker-core-linux-build-environment` is from 2015 (CentOS 6, CUDA 7.0). Later cores ran from CentOS 7.9 paths, and core24 needs glibc 2.33/2.34 [R]. Windows cores use Visual C++ [R]. Chodera, 2021-09-20: "we have migrated the build infrastructure to use the OpenMM conda-forge packages, which *do* support both osx-64 and osx-arm64" [V]. He planned osx core22 test builds in 2021 and 2022 ("only a tiny fraction of a developer ... this is actually next on our list", 2022-02-26) [V]. None shipped.
- **conda-forge today** [V]: `openmm-feedstock` is at 8.6.1 and builds `osx_arm64` with `opencl_impl=apple`. `MACOSX_DEPLOYMENT_TARGET` and `MACOSX_SDK_VERSION` are both 11.0. Metal needs MSL 3.1, so macOS 14 at runtime; Eastman accepted that floor on 2026-09-21. The Metal package therefore needs a runtime gate and possibly a newer SDK [I].
- **macOS arm64 CPU core** [R]: Joe_H, 2023-12-26: "The v8 Public Beta fully supports Apple Silicon, both the client and CPU folding cores have been compiled [to] use the Apple native machine code." The a8 core is listed for "Windows, Linux, macOS and ARM". The FAH macOS client ships as a universal binary (sibling report). **No GPU core has ever shipped for macOS** [R, every staff statement 2020 to 2026].
- **Species and constraints** [V]: gpus.json has 1890 rows `{vendor, device, type, species, description}`. Species runs 0 to 11 (0 means blocked); types are 1 AMD, 2 NVIDIA, 3 Intel. There are no Apple rows. The client marks a GPU supported only if it has species > 0 and was found by OpenCL/CUDA/HIP on the PCI walk (`GPUResources.cpp:194-221`). fah-gpu-species' README: species is "used to constrain which GPUs can run work for a given project", for example `NVIDIAGPUSpecies >= 3` [V]. Projects add AS constraints such as `ProjectKey=<n>` (alchemiscale-fah deployment docs) [V]. Low-end iGPUs sit at species 1 (Kaveri, Skylake HD 530) [V], so a small Apple GPU is not out of range [I].

## 4. Public statements on Apple GPUs and Metal (who said what)

| Date | Who (role) | Statement | Link |
|---|---|---|---|
| 2019-11-28 | John Chodera | Opens "Future of osx GPU support": Metal platform or extend OpenCL/CUDA? | openmm#2489 |
| 2020-03-31 | Chodera | "we just haven't had the developer effort to build osx cores" | openmm#2489 |
| 2020-11-18 | Joe_H (site admin) | "Unless support for Metal is added to OpenMM and a GPU folding core created it will not be usable for folding." | forum t=36425 |
| 2020-12-14 | Chodera | ARM cores for M1 in progress; "It may take a while before we can use the GPU" | forum t=36454 p2 |
| 2021-09-20 | Chodera | Builds moved to conda-forge packages that support osx-arm64; osx builds to follow | openmm#2489 |
| 2022-02-26 | Chodera | osx core22 "hasn't been abandoned ... next on our list" | openmm#2489 |
| 2022-08-15 | Peter Eastman | No plans for Metal: big task, OpenCL works, Macs rarely used for production, "Apple GPUs don't support double precision" | openmm#2489 |
| 2022-10-20 | Chodera | Would target OpenCL first; didn't know Apple lacked FP64; Apple-specific platforms need "significant financial support"; "Even single precision only can be useful" | openmm#2489 |
| 2024-11-05 | muziqaz (tester) | "There are no plans to support Apple GPUs", because OpenMM lacks Metal | fah-client-bastet#303 |
| 2024-11-06 | muziqaz | HIP first; "After that it is possible we can ask to look into Apple GPU stuff" | #303 |
| 2024-12-22 | Joe_H; calxalot (moderator) | "Metal is not supported at this time in OpenMM"; nobody has tried a fahcore on Apple OpenCL; an earlier Metal plugin stopped when no speedup appeared | forum p=366565 |
| 2025-01-01 | Eastman | Metal "possible, but right now I don't see any advantages over OpenCL" | openmm#2489 |
| 2025-11-14 | muziqaz | "there will not going to be a new fahcore supporting Apple GPUs ... market with 100 users" | #303 |
| 2025-11-18 | Joseph Coffland (lead dev) | Apple GPUs aren't on PCI; "We'd need a completely different strategy" | #303 |
| 2025-12-17 | Joe_H | "no plans to develop a GPU folding core for macOS"; no FP64, "which all current GPU cores require" | forum t=43406 |
| 2025-12-18 | Joe_H | Direction is set by "Greg Bowman ... Vincent Voelz and John Chodera ... They are the ones who pay Joseph and ultimately direct what he spends time on." | forum t=43406 p2 |
| 2025-12-18 | calxalot | "Joseph has already accepted GPU support on Apple as an enhancement request ... Volunteers can do a lot of the lifting." | forum t=43406 p2 |
| 2026-01-20 | Joe_H | No FP64 on Apple iGPUs; no PCI ID; limited developer bandwidth | forum t=43450 |
| 2026-01-28 | Coffland | Three-step non-PCI plan (gpus.json IDs, AS/DB, client enumeration): "This is a priority though." | #303 |
| 2026-09-21 | Eastman | macOS 14 floor fine; "Apple GPUs don't support double precision, so using double precision mode isn't an option anyway." | openmm#5397 |

Who decides [R]: consortium leadership (Bowman, Voelz, Chodera) sets priorities and funds Coffland. The GPU FAHCore team builds and validates cores. Coffland owns client, AS and DB. Eastman gates what goes into OpenMM. muziqaz and Joe_H are influential but don't decide.

## 5. Ranked "make it easy for them" checklist

Each item removes work the FAH core team would otherwise do or a risk they would otherwise carry. The order follows dependency and how much each item de-risks.

1. **Metal in a released OpenMM.** FAH doesn't take betas (toTOW, 2025-05-09), and every core pins a release. Do it Eastman's way: common compute derived from CUDA/HIP (#5416, 2026-09-07), AI use disclosed per `AI_POLICY.md` (#5397, 2026-09-09). Without this, nothing else counts.
2. **Metal in conda-forge `openmm` for osx-arm64,** with a runtime gate for macOS < 14 and checks on the SDK 11.0 build and static target. FAH builds cores from conda-forge packages (Chodera, 2021). Kernels compile from MSL source at runtime (`MetalContext.cpp:489-493`), so there's no NVRTC-style toolchain to ship; say so explicitly, since toolchain packaging is what delayed CUDA. `libOpenMMMetal_static.a` exists (`platforms/metal/CMakeLists.txt:111-120`). Test that a static link registers the platform.
3. **A validation pack in FAH's own terms,** so the HIP-style "same results as OpenCL/CUDA" step is already done:
   - A harness that replicates `StateTests` exactly: NaN, velocity cap 17.47, force cap 50,000, |F| RMSE ≤ 5, |ΔE| ≤ 10 (report margin to 20).
   - Run it at start and at every 5% checkpoint, from FAH-format inputs (`core.xml` + `system/integrator/state.xml.bz2`), with a checkpoint → reload → bitwise continuation test. Our C2 mock core is the base.
   - Systems: fah-bench's dhfr, dhfr-implicit and nav; one ≥ 1M-atom PME system; one multi-million-atom system if memory allows. Report absolute |ΔE| in kJ/mol, not relative.
   - Chips: M1/M2/M3/M4 (M5 if available), with pass rates over hundreds of starts and a cross-check against CUDA mixed on the same inputs.
   - Long runs: NVE drift and 10× ns-scale runs with zero NaN/"Bad State".
   - One page answering the Arc question head-on: what df64 is, why it isn't driver emulation, and the evidence it doesn't give "inconsistent results" or crash.
4. **Property parity with HIP.** Accept `DeviceIndex` ("0"), `Precision`, `DisablePmeStream`, `DeterministicForces`, `UseBlockingSync` and `UseCpuPme` with HIP semantics, and reject `double` cleanly (C1). The core's CUDA/HIP branch then works unchanged apart from the platform name. Document that forces are deterministic by construction, so `DeterministicForces=true` costs nothing.
5. **Client non-PCI detection as a PR that follows Coffland's plan** (step 3, client enumeration; IDs in his `<bus>:<vendor>:<device>` shape). Put it up as a draft plus a comment on #303. The sibling report has the patch design. Steps 1 and 2 (gpus.json format, AS/DB) are FAH's.
6. **Species data.** ns/day and ms/step, Metal mixed, on the FAH benchmark projects (p11733-like dhfr and similar), for each chip. Put them next to published numbers for species 1 to 4 GPUs so the whitelist entry is a lookup, not a study. Include Apple vendor 0x106b and the IOKit device IDs.
7. **An integration note for the core team.** The expected core diff: a `metal` value for `-gpu-platform`, or core-side selection when OS=macOS and arch=arm64; the property map; plugin/static registration; macOS 14 gate. Also the "what we can't do" list (no double, no FP64 hardware).
8. **Then, and only then, contact.** Take items 1 to 3 to the people named in section 4 (Chodera's lab, where the FAHCore team sits; Coffland for client/AS). Outreach is paused per PROGRAM.md; this is sequencing advice, not a request to send anything.

## Caveats

- The FAH core is closed. The state-test mapping to FAHBench rests on identical message strings and shared authorship. The threshold of 20 in live logs vs FAHBench's 10 suggests projects override `energyTolerance`, or the core default changed. I couldn't tell which.
- "CPU" vs "Reference" for the core's comparison is unresolved. Staff say CPU; FAHBench uses Reference.
- The precision default of "single" comes from a third party's documentation of core.xml (OpenFE's alchemiscale-fah), not from FAH. The FAH README it copies is private.
- Core24/27 dates and the core22 CUDA blog text come from search snippets. The blog URL now returns 404.
- I didn't verify whether Battlemage or Lunar Lake have native FP64. Joe_H had no data on 2024-12-03.
- calxalot's 2025-12-17 remark that engineering support "requires department vice president or higher approval level" doesn't say which organization it refers to. I left it out of the "who decides" list.
- The core28 project number is given as both 18289 and 19289 on forum page 3.

## Pointers

- `FoldingAtHome/fah-bench` `fahbench/StateTests.cpp`, `Simulation.cpp`: the closest public copy of the core's checks. Port it verbatim into the C2 harness.
- `OpenFreeEnergy/alchemiscale-fah` `alchemiscale_fah/settings/fah_settings.py` and `docs/deployment.rst`: the fullest public description of `core.xml` and how projects and constraints are set up.
- `FoldingAtHome/fah-client-bastet` `src/fah/client/Core.cpp`, `Unit.cpp:639-667`, `GPUResources.cpp`: signing, the core CLI, and the PCI drop. See the sibling report for the patch.
- openmm#2489 and #5397: the full history of FAH and OpenMM positions on macOS GPUs, and Eastman's current design direction for Metal.
- forum t=43534 (3 pages): how the HIP core went from announcement to full FAH. It's the template for what they'll ask of Metal.

## Sources

- https://forum.foldingathome.org/viewtopic.php?t=43534 (HIP core28 announcement, 2026-03-28; pages &start=15, &start=30)
- https://forum.foldingathome.org/viewtopic.php?t=43416 (8.5 = HIP?, 2025-12-25)
- https://forum.foldingathome.org/viewtopic.php?p=369692 (core26/27, 2025)
- https://forum.foldingathome.org/viewtopic.php?t=42405 (core26 released to full FAH?)
- https://forum.foldingathome.org/viewtopic.php?t=40568 (core23 announcement, 2023-08-26)
- https://forum.foldingathome.org/viewtopic.php?f=24&t=31454 (core22 announcement, 2019-03-14)
- https://foldingathome.org/2020/09/28/foldingathome-gets-cuda-support/ (CUDA core22 0.0.13; now 404)
- https://forum.foldingathome.org/viewtopic.php?t=38718 (checkpoints and sanity checks, 2022-11)
- https://forum.foldingathome.org/viewtopic.php?t=41188 (checkpoint frequency, 2024-02-23)
- https://forum.foldingathome.org/viewtopic.php?nomobile=1&f=19&t=36921 (Force RMSE, 2021-03)
- https://forum.foldingathome.org/viewtopic.php?f=19&t=32660 (Bad State log, 2020-03)
- https://forum.foldingathome.org/viewtopic.php?t=42176 (Potential energy error, core24)
- https://github.com/FoldingAtHome/fah-web-client-bastet/issues/167 (energy error log, 2024-07-24)
- https://forum.foldingathome.org/viewtopic.php?t=40766 (FP64 required, 2024-07-13)
- https://forum.foldingathome.org/viewtopic.php?t=38527 (Arc FP64 emulation, 2022-10)
- https://forum.foldingathome.org/viewtopic.php?t=42257 (Battlemage whitelisted, 2024-12)
- https://forum.foldingathome.org/viewtopic.php?t=43406 (Apple M1 to M4, 2025-12; &start=15)
- https://forum.foldingathome.org/viewtopic.php?t=43450 (2026 hardware audit thread, 2026-01)
- https://forum.foldingathome.org/viewtopic.php?p=366565 (M4 Mac mini, 2024-12)
- https://forum.foldingathome.org/viewtopic.php?t=40941 (M3 family, 2023-12)
- https://forum.foldingathome.org/viewtopic.php?f=16&t=36425 and https://forum.foldingathome.org/viewtopic.php?t=36454&start=15 (2020)
- https://forum.foldingathome.org/viewtopic.php?t=38650 (GPU WU on Mac Studio)
- https://github.com/FoldingAtHome/fah-client-bastet/issues/303 and https://github.com/FoldingAtHome/fah-client-bastet/pull/442
- https://github.com/FoldingAtHome/fah-bench (StateTests.cpp, Simulation.cpp)
- https://github.com/FoldingAtHome/openmm (FAH fork branches)
- https://github.com/FoldingAtHome/fah-gpu-species
- https://api.foldingathome.org/gpus (fetched 2026-09-23)
- https://github.com/OpenFreeEnergy/alchemiscale-fah
- https://github.com/choderalab/perses/blob/main/perses/app/fah_generator.py and https://github.com/choderalab/fah-xchem
- https://github.com/openmm/openmm/issues/2489, /issues/5008, /issues/5397, /pull/5416, /pull/4632, release 8.2.0
- https://github.com/conda-forge/openmm-feedstock
- https://en.wikipedia.org/wiki/List_of_Folding@home_cores
- https://www.cnx-software.com/2020/08/14/foldinghome-arm64-linux-beta-release-for-covid-19-vaccine-research/

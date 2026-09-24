# Does Folding@home need mixed precision on GPUs? (2026-09-24, fah-precision)

Short answer: yes for today's production path, with a per-project caveat.

## For
- FAH moderator Joe_H, Apple M1-M4 whitelist thread, 2025-12-17, replying to an M-series clinfo with no double support: "Currently all GPU folding cores for F@H enable that and use it for some critical calculations during WU processing." https://forum.foldingathome.org/viewtopic.php?t=43406
- calxalot, 2025-01-15: "Yes. Hardware FP64 is required." Joe_H: FP64 required for 6 to 7 years, most math in single; Intel Gen12 emulated FP64 "was not stable enough." https://forum.foldingathome.org/viewtopic.php?t=42401
- Live whitelist https://api.foldingathome.org/gpus (1,890 rows, fetched 2026-09-24): every Intel DG2/Arc Alchemist device species 0, described "-no FP64 support". No Apple rows (vendors 0x1002, 0x10de, 0x8086 only).
- Core22 launch post (rafwiewiora, 2019-03-14) lists "precision: mixed" as a project stat. https://forum.foldingathome.org/viewtopic.php?f=24&t=31454
- bruce 2019: "FAH now uses 'mixed precision' (almost) all of the time." PantherX 2020: "F@H now uses mixed precision on GPUs." https://foldingforum.org/viewtopic.php?t=24225&start=165
- OpenMM OpenCL skips devices without cl_khr_fp64 for mixed/double and throws "This device does not support double precision" for an explicit pick. Default precision is single (OpenCLPlatform.cpp:118).
- peastman 2022-10-20: M1 Pro has no fp64, so no mixed on macOS OpenCL. https://github.com/openmm/openmm/issues/2489#issuecomment-1286238183
- peastman 2022-10-21: mixed = double energy accumulation and integration; integration about 5 percent of GPU time. https://github.com/openmm/openmm/issues/2489#issuecomment-1287441490
- peastman 2022-11-17 on FAH using a Metal plugin: "Yes, that ought to be possible." https://github.com/openmm/openmm/issues/2489#issuecomment-1317902792

## Against, or complicating
- Chodera 2022-10-20: "Even single precision only can be useful for some of our workloads in supporting antiviral discovery!" https://github.com/openmm/openmm/issues/2489#issuecomment-1286215541
- peastman 2022-11-17: compensated summation could give accurate energies on M1 OpenCL without double; integration harder but less important. An OpenCL-only alternative. https://github.com/openmm/openmm/issues/2489#issuecomment-1317854917
- peastman 2024-11-05: "We don't have any current plans to add Metal support. The OpenCL platform works fine." https://github.com/openmm/openmm/issues/2489#issuecomment-2458200166
- #303, muziqaz: no plans to support Apple GPUs; no new fahcore for Apple GPUs even with client support; cores closed source. kbernhagen: unknown whether Apple OpenCL OpenMM can do what a FahCore needs. jcoffland: non-PCI plan is "a priority", time is the blocker.
- Joe_H 2025-12-18 claims OpenMM can push FP64 work to the CPU; no such OpenMM feature found (only UseCpuPme). Don't cite.

## Unknowns
- No Core22+ log line showing precision; no developer statement on precision after 2019. Precision may be per project, so single-precision projects can't be ruled out.

## Inference
"FAH GPU cores need fp64 today" is solid. "FAH would refuse a single-precision Apple core" is not. The pitch that holds: Metal's df64 mixed mode lets Apple GPUs run the precision FAH already uses on every whitelisted GPU, without a separate single-precision core and its own validation. The counter to expect: compensated summation in OpenCL.

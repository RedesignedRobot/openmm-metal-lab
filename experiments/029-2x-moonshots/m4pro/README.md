# M4 Pro check, 2026-10-01

This was a one-off check of whether trunk runs on an M4 Pro. The M4 Pro is a MacBook Pro 14 (Mac16,8) reached over SSH, and it isn't a program host. I copied the trunk build 734ce92d5 (`ultra-integrated`, Xcode-beta 27.2) from the Studio and ran it unmodified. Nothing was rebuilt for the M4.

Short answer: it works. The forces gate passed, and so did 58 of 58 core C++ tests. Metal beat OpenCL on every benchmark row. The M4 takes every Apple9 code path tuned on the M3 Ultra. The only difference is that the policies scaled by GPU core count see 16 cores instead of 60.

Afterwards I deleted the copy and the `/tmp/openmm-metal-bench` symlink. Homebrew `coreutils` stays installed (for `gtimeout`).

## The chip

| | M4 Pro (this check) | M3 Ultra (Studio) |
|---|---|---|
| Metal architecture | applegpu_g16s | applegpu_g15d |
| Driver | AGXAcceleratorG16X, plugin AGXMetalG16X | AGXAcceleratorG15X, plugin AGXMetalG15X_M2 |
| GPU cores enabled / on die | 16 / 20 (2 mgpus, core_mask 987,987 = 8 of 10 each) | 60 / 80 (8 mgpus) |
| gpu_gen, usc_gen | 16, 3 | 15, 3 |
| GPU families | Apple7, 8, 9, Metal3, Metal4, Mac2. Not Apple10 | same |
| SIMD width | 32 | 32 |
| Threadgroup memory | 32 KiB | 32 KiB |
| Max threads per threadgroup | 1024 | 1024 |
| recommendedMaxWorkingSetSize | 17.76 GiB | 77.76 GiB |
| maxBufferLength | 13.32 GiB | 58.32 GiB |
| GPU clock states | 338 to 1578 MHz, 15 listed states | not sampled |
| Unified memory | 24 GB | 96 GB |
| CPU | 8 P + 4 E | 20 P + 8 E |
| P-core caches | L1i 192 KiB, L1d 128 KiB, L2 16 MiB per 4-core cluster | L2 16 MiB |
| E-core caches | L1d 64 KiB, L2 4 MiB | |
| Line and page size | 128 B line, 16 KiB page | |
| CPU ISA extras | SME, SME2, SME F64F64, BF16, I8MM, DotProd, FP16 | |

The sources are `raw/sysctl-ioreg-m4pro.txt`, `raw/mtlprobe-m4pro.txt` and `raw/mtlprobe-m3ultra.txt`. The Ultra probe was a device query only, with no timing, so it didn't disturb the other runs.

## GPU microbenchmarks (M4 Pro)

The kernels are in `mtlprobe.m`. Timings are GPU timestamps, best of 5 after one warm-up. The laptop had a browser open, so treat them as floors.

| Measure | Result | Against peak |
|---|---|---|
| 1 GiB copy, private buffers | 225 to 226 GB/s read+write | 83% of Apple's 273 GB/s |
| FP32 FMA, 6 independent chains | 5.37 TFLOPS | 83% of 6.46 (16 cores x 128 lanes x 2 x 1.578 GHz, assuming 128 FP32 lanes per core) |
| Relaxed atomic add, 16 MiB grid | float 5.75, uint 5.78 Gop/s | |
| Relaxed atomic add, 16 KiB grid (cache resident) | float 28.4, uint 28.4 Gop/s | |

Float atomic add costs the same as uint atomic add. That makes it a hardware float atomic, as on the M3. The Apple9 PME float spread (`supportsHardwareFloatGlobalAtomicAdd`) depends on this.

GPU clock (sudo powermetrics, gpu_power, 250 ms samples, `raw/powermetrics-busy.txt`): under load the GPU sat at 1571 to 1578 MHz and drew 7.4 to 9.2 W. Between bursts it dropped to 338 MHz within one sample.

## Correctness

- Forces: `tools/forces.py` against the double-precision Reference, 6 systems, single and mixed. All 12 rows passed against the Ultra's trunk gate table (`raw/forces-ultra-gate-20260930T065657Z.txt`). rel|dF| matches the Ultra to 3 or 4 digits: apoa1pme single is 7.676e-05 on both, and gbsa is 2.468e-05 against 2.472e-05. See `raw/forces-m4pro.txt`.
- C++ tests: 29 TestMetal binaries, each in single and mixed, 58 of 58 PASS, 647 s wall (`raw/ctest.txt`, `m4ctest.sh`). The set was NonbondedForce, CustomNonbondedForce, Ewald, FFT, Sort, GBSAOBCForce, CustomGBForce, the bonded forces, Settle, VirtualSites, the Langevin, Verlet and Custom integrators, MonteCarloBarostat, MixedPrecision, LocalEnergyMinimizer, CommandBatching, MultipleForces, Checkpoints, DispersionPME, GayBerneForce, AmoebaMultipoleForce, AmoebaGeneralizedKirkwoodForce, DrudeForce and Rpmd.
- Not run: the full gate (the other 38 TestMetal binaries), md100, DeterministicForces and listcheck.

## Speed

Method: benchmark.py, 15 s, one round per arm, host clock. The machine wasn't dedicated: a browser was open and the load average was 3 to 4. The ratios compare against OpenCL in the same session. The Ultra column is w4's trunk arm (3x30 s, night slot) from before the 734ce92d5 merge. Raw data is in `raw/bench-m4pro.txt`.

| Test | M4 Pro Metal single ns/day | M4 single/OpenCL | M4 mixed/OpenCL | Ultra single/OpenCL (w4) | Ultra mixed/OpenCL (w4) | M4 / Ultra ns/day, single |
|---|---:|---:|---:|---:|---:|---:|
| gbsa | 968 | 1.13 | 1.15 | 1.88 | 1.65 | 0.44 |
| rf | 741 | 1.43 | 1.36 | 2.59 | 2.30 | 0.43 |
| pme | 572 | 1.44 | 1.37 | 2.46 | 2.25 | 0.45 |
| apoa1rf | 223 | 1.73 | 1.54 | 2.11 | 1.91 | 0.38 |
| apoa1pme | 171 | 1.66 | 1.55 | 2.37 | 2.20 | 0.40 |
| apoa1ljpme | 130 | 1.74 | 1.65 | 2.47 | 2.34 | 0.41 |

- The M4 Pro has 27% of the Ultra's enabled GPU cores (16 of 60), and it runs at 38 to 45% of the Ultra's ns/day. Each core does 1.4 to 1.7 times the work.
- The ratios on the 92k-atom apoa1 systems come close to the Ultra's. The small systems fall well short: gbsa is 1.13 against 1.88.
- Mixed holds up better than on the M2. On the 028 tip, the M2's mixed/OpenCL was 0.91 to 1.16 on these six tests (`M2-DENOMINATOR.json`). Here it's 1.15 to 1.65.
- One oddity: gbsa mixed (983) beat gbsa single (968). A 3 s gbsa single run in the same session gave 1042 ns/day, so I read this as noise from the shared machine.

## Which tuned paths the M4 Pro takes

These branches are keyed on `supportsFamily(Apple9)`, and all of them are on for the M4 Pro:
- Float-atomic PME spread (`MetalContext.cpp:250`).
- The Metal FFT instead of VkFFT (`MetalFFT3D.cpp:59`).
- Indirect list rebuild (`MetalNonbondedUtilities.cpp:92`).
- MAX_BITS 0 under 100k atoms outside LJPME (`:675`).
- Force-pass kernels (`MetalContext.cpp:876`).

The paths scaled by `gpu-core-count` from the IORegistry (`MetalContext.cpp:261`) come out as follows:

| Policy | Formula | M4 Pro (16) | M3 Ultra (60) |
|---|---|---:|---:|
| numThreadBlocks | 12 x cores | 192 | 720 |
| Force thread blocks | 40 x cores (160 x above 90k atoms) | 640 / 2560 | 2400 / 9600 |
| Batch-4 tiles | numAtomBlocks < 64 x cores (`MetalNonbondedUtilities.cpp:325`) | under 1024 blocks | under 3840 blocks |

The batch-4 row matters. gbsa (78 blocks) and rf and pme (737 blocks) get batch-4 on both chips. apoa1 (2882 blocks) gets batch-4 on the Ultra and batch-1 on the M4 Pro. The cut came from the Ultra (8fa089cee, "raised to 64 blocks per core"), and nobody has measured it on a 16-core GPU.

## Open questions this raises

1. Does apoa1 on a 16-core GPU gain from batch-4? This is a cheap A/B: force `numTilesInBatch` to 4 and run apoa1rf/apoa1pme on the M4 Pro. If it wins, the cut belongs in threads or blocks per core rather than a fixed 64.
2. Why gbsa falls short (1.13x): my guess is per-step launch cost plus the drop to 338 MHz between command buffers. The r3-fah keep-alive idea goes after the same idle clock-down, and a small GPU might show it more. Neither is measured on the M4 Pro.
3. SME2 with F64F64 on the M4 CPU could matter for the CPU platform and the mixed minimizer. It's outside 029's scope.

## How to repeat it

The build is relocatable enough to copy between Apple Silicon Macs with no Xcode, swig or Metal compiler on the target. Kernels compile at load time through Metal.framework.
1. On the target, create `~/openmm-m4check`, then `ln -s ~/openmm-m4check /tmp/openmm-metal-bench`, so the absolute rpaths and the compiled-in plugin path resolve.
2. From the Studio's bench, stream `env`, `ultra-integrated/{prefix,venv,pydeps,BUILT}`, `ultra-integrated/build/*.dylib` and `ultra-integrated/build/TestMetal*` (595 MB) into it. Add `ultra-base/benchmarks/{benchmark.py,*.pdb}`, `tools/forces.py`, `tools/cutoff_pairs.py` and the trunk gate's `forces.txt` (kept here as `raw/forces-ultra-gate-20260930T065657Z.txt`).
3. `. m4env.sh` sets `DYLD_FALLBACK_LIBRARY_PATH` to `env/lib`, because the `_openmm` rpath points at the Studio's env path. It also sets `OPENMM_PLUGIN_DIR` and `$PY`. Then run `forces.py`, `m4ctest.sh` and `m4bench.sh`. macOS has no `timeout`, so the scripts use Homebrew's `gtimeout`.
4. The Studio had no direct SSH route to the M4 Pro, so the files streamed through another Mac over SSH, which stored nothing.

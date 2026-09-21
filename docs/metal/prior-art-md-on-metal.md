# Prior art: molecular dynamics and scientific compute on Metal

This document analyzes prior implementations of molecular dynamics (MD), scientific compute kernels, and particle acceleration structures on Apple Silicon Metal. It evaluates what techniques succeed, what fails, measured performance numbers against OpenCL and CPU baselines, and architectural lessons for an OpenMM native Metal platform.

## Systems evaluated

1. **`openmm-metal` (Philip Turner)**
   - Repository: `philipturner/openmm-metal` at commit `f14cecdb11056da03b5373c88f0a056a764403ad`.
   - Scope: OpenMM plugin targeting Apple, AMD, and Intel GPUs on macOS Ventura and higher.
   - Architecture: Wraps OpenCL kernels using Apple's internal `cl2Metal` driver layer (`platforms/metal/src/MetalProgram.cpp`, lines 35-43). Uses VkFFT for 3D FFTs (`platforms/metal/src/MetalFFT3D.cpp`).

2. **OpenMM `Objective-C` branch (Chun-Chi Hung / NORPG)**
   - Commit: `8f6a7332f4bca326cd43366f2916da396db661ae` on `openmm/openmm`.
   - Discussion: OpenMM issue #5397 (August-September 2026).
   - Scope: Prototype C++ Common compute backend implemented in Objective-C++ (`.mm`) using native Metal framework APIs (`platforms/metal/src/MetalKernel.mm`, `platforms/metal/src/MetalQueue.mm`).

3. **`moleqular` (Alex MacCaw)**
   - Repository: `maccaw/moleqular` at commit `be897a144f672a839ce2ca3bbe94d4a0e8ea8dec`.
   - Scope: Lennard-Jones molecular dynamics engine on Apple Silicon M4 exploring NEON, OpenMP, Metal all-pairs, GPU cell lists, NBNXM cluster pairs, bounding volume hierarchies (BVH), and Apple Neural Engine (ANE).

4. **`mlx-atomistic` (App Automaton)**
   - Repository: `appautomaton/mlx-atomistic` at commit `2813bed7b8a1fe11dd26d4b235c4ba21002c681c`.
   - Scope: Production Apple Silicon runtime for molecular dynamics and plane-wave density functional theory (DFT) on Apple Silicon M5 Max. Contains production ledger of kernel experiments (`docs/benchmarks/md-performance-decisions-m5max.md`).

5. **`metal-sci-kernels` (arXiv:2605.09708)**
   - Repository: `metal-sci-kernels` at commit `091685c8c3800263275d3a2bdef5509b20870e64`.
   - Scope: 12-task scientific compute benchmark for Apple Silicon Metal kernels with roofline-anchored evaluations on M1 through M4 chips.

6. **GROMACS and LAMMPS status**
   - Upstream codebases and documentation for GROMACS 2024+ and LAMMPS stable releases.

7. **`molecular-renderer` (Philip Turner)**
   - Repository: `philipturner/molecular-renderer` at commit `fc7260c1e7a81f14e53b6c157963b7b6be07c0ac`.
   - Scope: Real-time molecular graphics and spatial acceleration structures on Metal.

---

## Measured performance and what works

### OpenMM Metal plugin (`openmm-metal`)

The `openmm-metal` plugin demonstrated that Apple GPUs can run complete OpenMM simulation pipelines faster than Apple's deprecated OpenCL driver.

#### ApoA1 reaction field benchmark
On the `apoa1rf` benchmark (reaction field electrostatics without reciprocal space FFT), `openmm-metal` achieved 150 ns/day on Apple Silicon, compared to 110 ns/day on OpenCL (a 1.36x speedup, cited by Philip Turner in OpenMM issue #5397, comments 2 and 4). Turner noted that early OpenMM runs on M1 Max were 6x slower than a GTX 1080 despite equal theoretical GFLOPS. Two changes resolved the gap:
1. **Reporting accurate SIMD width:** OpenCL reported a wave width of 64 or fell back to scalar execution on Apple Silicon. Forcing 32-wide SIMD execution unlocked a 4-fold throughput gain.
2. **SIMD-scoped reductions:** Replacing global memory atomic reductions with `simd_sum` in neighbor-list generation closed the remaining gap.

#### Energy reduction latency
In standard OpenMM OpenCL, the `reduceEnergy` kernel serialized summation across a single workgroup, requiring ~65 µs per invocation across all system sizes (96 to 4,158 atoms). In `openmm-metal`, splitting reduction across 1,024 threadgroups (`OPENMM_METAL_REDUCE_ENERGY_THREADGROUPS=1024`) dropped kernel execution time to 6-9 µs in Perfetto traces (`openmm-metal/README.md`, lines 112-132).

#### Profiling breakdown of OpenCL on M4 Max
Peter Eastman profiled the `apoa1pme` benchmark on an M4 Max GPU using OpenCL (OpenMM issue #5397, comment 3, August 25, 2026):

| Kernel | Fraction of time |
|---|---|
| `computeNonbonded` | 32.7% |
| `findBlocksWithInteractions` | 23.6% |
| `gridSpreadCharge` | 13.5% |
| `computeBondedForces` | 8.26% |
| `computeRange` | 3.37% |
| `gridInterpolateForce` | 2.60% |
| `sortBuckets` | 2.45% |
| `finishSpreadCharge` | 1.16% |

The top three kernels (`computeNonbonded`, `findBlocksWithInteractions`, and `gridSpreadCharge`) account for 69.8% of GPU execution time. VkFFT accounted for approximately 10% of the timeline.

---

### `moleqular`: Lennard-Jones molecular dynamics on M4

Alex MacCaw implemented and benchmarked multiple MD algorithms on a base M4 chip (10 GPU cores, 4 P-cores, 6 E-cores, 4.5 TFLOPS FP32 peak) (`moleqular/README.md`):

#### All-pairs nonbonded forces
- Tiled Metal kernel using threadgroup memory (`shared memory`) to amortize j-particle loads across 128 threads reached 810 GFLOPS (19% of peak FP32).
- Comparison with NVIDIA L4 (58 SMs, 30.3 TFLOPS peak): L4 reached 6,821 GFLOPS (22% peak). Both GPUs hit the identical serial dependency chain in the Lennard-Jones calculation. L4 was 8.4x faster in wall time, directly matching the 7.1x ratio of hardware ALUs.

#### Cell lists vs all-pairs
- CPU cell list gave a 340x speedup over all-pairs at 87,000 particles.
- GPU cell list gave a 45x speedup over all-pairs at 70,304 particles.
- However, GPU cell lists suffered severe SIMD divergence: each thread in a 32-thread SIMD group traversed different neighbor cells with different particle counts. This dropped per-pair computational efficiency from 19% to under 3% of peak FLOPS.

#### NBNXM cluster-pair neighbor lists
To restore SIMD convergence while preserving $O(N)$ scaling, `moleqular` adopted GROMACS-style 8x8 cluster pair lists:
- One threadgroup (64 threads) processes one i-cluster (8 particles).
- All threads read the same j-cluster from threadgroup memory, eliminating SIMD divergence.
- Measured timings (ms per step):

| Particle count ($N$) | GPU Cell List | GPU NBNXM Cluster Pairs | Faster |
|---|---|---|---|
| 864 | 0.59 ms | 0.38 ms | NBNXM (1.6x) |
| 4,000 | 0.70 ms | 0.75 ms | Tie |
| 10,976 | 1.07 ms | 1.39 ms | Cell list (1.3x) |
| 32,000 | 2.25 ms | 3.28 ms | Cell list (1.5x) |
| 62,500 | 3.89 ms | 3.33 ms | NBNXM (1.2x) |

NBNXM won at small $N$ due to higher threadgroup occupancy and at large $N$ ($62.5\text{K}+$) because SIMD coherence dominated memory latency. At intermediate sizes ($4\text{K}-32\text{K}$), the 8x padding overhead (evaluating empty interaction slots in liquid) gave cell lists a temporary advantage.

---

### `mlx-atomistic`: Production MD ledger on M5 Max

`mlx-atomistic` maintained an empirical optimization ledger on an Apple Silicon M5 Max running production biological benchmarks: 5DFR (24,895 atoms), JAC (94,232 atoms), and GPCRmd (103,145 atoms) (`docs/benchmarks/md-performance-decisions-m5max.md`).

#### Successful techniques and measured speedups
1. **Analytical SETTLE constraint solver (`d3b264b`):** Replaced iterative SHAKE/RATTLE (roughly 60 full-array iterations per step) with an analytical 3-site water solver. 750-step JAC wall time dropped by 52.3%.
2. **Interaction32 atomic force tiles (`e4c631d`, `8c029c2`):** Fused 32-atom interaction tiles accumulating forces via device atomics (`fused_half32`). Improved 750-step wall times by 19.39% on 5DFR, 22.33% on JAC, and 23.09% on GPCRmd.
3. **Two-level Verlet neighbor schedule (`e4c631d`):** Maintained an inner schedule with a 3.0 Å skin and an outer schedule with a 2.75 Å skin. Compacted pairs on the fly and triggered rebuilds only when maximum atom displacement exceeded 1.5 Å. Systems averaging at least 24 steps per generation improved JAC throughput by 4.72% to 6.15%.
4. **Real half-spectrum PME FFT (`rfft`):** Replacing full complex-to-complex FFT with real-to-complex transform ($N_x \times N_y \times [N_z/2 + 1]$) reduced reciprocal-space workload by 56%.
5. **Inline active-right compaction (`acd05c6`):** Compacted active interaction pairs within SIMD groups and transposed the pair loop. Improved fixed-input Direct blocks by 24.6% on JAC and 25.3% on GPCRmd; sustained step throughput improved 3.93% to 8.86%.
6. **Constant-time special membership bitset (`360219a`):** Replaced binary search over 1-4 and exclusion lists with generation-owned bitsets. Fixed-input count kernels improved 62.48% on JAC; sustained throughput improved 4.74% to 6.80%.
7. **Speculative neighbor admission overlap (`f18c2e8`):** Dispatched displacement check kernels before the current-generation force graph. Yielded 37.92% improvement on 5DFR, 8.77% on JAC, and 7.75% on GPCRmd.

#### MLX vs OpenMM matched benchmark
On JAC (94,232 atoms, 4 fs timestep, PME electrostatics, Amber ff14SB, 10 warmup steps, 750 measured steps on M5 Max):
- Baseline MLX: 4.813 ms/step (71.81 ns/day) at commit `97ea8d2`.
- OpenMM 8.5.1.dev (single-precision OpenCL): 2.699 ms/step (128.03 ns/day). Ratio was 1.783.
- After speculative overlap and bitset improvements (`f18c2e8`): MLX reached 1.944 ms/step (177.8 ns/day) against OpenMM's 1.227 ms/step (281.5 ns/day), closing the gap to 1.584.

---

### `metal-sci-kernels`: Roofline limits on scientific kernels

The Metal-Sci benchmark suite (arXiv:2605.09708, commit `091685c8c3800263275d3a2bdef5509b20870e64`) evaluated Lennard-Jones (`lj`) and 3D FFT (`fft3d`) against theoretical hardware ceilings:
- **`lj` task:** Seed kernel used a naive cell-list spatial hash with atomic appending and 27-cell neighbor loops (`seeds/lj.metal`). At $N = 10,648$ particles on Apple GPU (ceiling 4,500 GFLOPS), the optimized kernel achieved 49.9 GFLOPS, only 1.1% of roofline ceiling (`results/lj_gpt-5.5_20260508_110713/best_result.json`). The bottleneck was memory scatter, threadgroup branch divergence, and atomic contention during cell construction.
- **`fft3d` task:** High fraction of roofline was achievable only by using `simd_shuffle` operations within SIMD groups and transposing dimensions through threadgroup memory without round-trips to DRAM.

---

### GROMACS and LAMMPS status on Metal

- **GROMACS:** GROMACS has no native Metal backend. On macOS, GROMACS relies on the deprecated Apple OpenCL runtime or experimental SYCL (via oneAPI/DPC++ with OpenCL backends). For 3D FFTs, GROMACS uses VkFFT or FFTW on CPU. Running GROMACS on Apple Silicon GPUs through OpenCL encounters driver bugs and lacks SIMD shuffle optimizations.
- **LAMMPS:** LAMMPS provides GPU acceleration through CUDA, HIP, and OpenCL packages. It has no Metal backend. The LAMMPS user documentation directs macOS users to run on CPU cores using multi-threading via OpenMP (`src/OPENMP`).

---

### `molecular-renderer`: Particle spatial acceleration structures

Philip Turner's `molecular-renderer` implemented real-time ray-traced sphere structures on Apple Silicon (`Documentation/bvh-update-process.md`):
- **Voxel hierarchy:** Subdivided space into 2 nm primary voxels and 0.25 nm sub-voxels.
- **FP16 coordinate compression:** Compressing atom positions from FP32 to FP16 inside 2 nm voxels reduced memory consumption from 96,264 bytes/voxel to 55,304 bytes/voxel (a 42.5% reduction), improving L2 cache hit rates.
- **Voxel atomic accumulation:** To avoid atomic serialization when assigning particles to voxels, each voxel maintained 8 duplicated atomic counters (`8x duplicated atomic counters`). Threads accumulated into a randomly assigned counter, and a subsequent reduction pass summed the 8 counters.
- **MetalFX and ANE compilation latency:** Using `MTLFXTemporalUpscaler` triggered `ANECompilerService` during initial pipeline creation, causing a 2-second to 10-second freeze at program startup (`Documentation/render-process.md`). Real-time simulations must avoid triggering runtime ANE compilations.

---

## Techniques worth copying

### Neighbor listing

1. **32-atom tile hierarchy (Interaction32 / NBNXM):**
   Group particles into tiles of 32 atoms matching Apple Silicon's 32-wide SIMD execution width. Summarize each 32-atom block with an axis-aligned bounding box (AABB). Compute bounding box overlap at the SIMD level. One SIMD thread tests one block pair, allowing a single 32-thread SIMD group to evaluate 1,024 particle pairs with zero divergence.
2. **Inline SIMD compaction:**
   When testing candidate neighbor pairs, prune non-overlapping bounding boxes using `simd_ballot` or `simd_prefix_inclusive_sum`. Compact surviving interaction indices within thread registers before executing expensive distance arithmetic.
3. **Two-level Verlet scheduling:**
   Separate neighbor listing into an inner schedule (e.g. 3.0 Å skin) and an outer schedule (e.g. 2.75 Å outer skin). Run the inner schedule for typical steps; evaluate maximum particle displacement on the GPU; transition to the outer schedule or trigger a full rebuild only when cumulative displacement exceeds the threshold (1.5 Å).
4. **Duplicated atomic counters for binning:**
   When binning atoms into grid cells or spatial buckets, allocate multiple atomic counters (4 or 8) per cell to distribute memory bank contention across threads, followed by a local threadgroup sum.

### Nonbonded force evaluation

1. **Threadgroup memory cooperative loading:**
   Launch kernels with 128 or 256 threads per threadgroup (4 or 8 SIMD groups). Cooperatively load j-particle coordinates and parameters into threadgroup memory (`threadgroup float4 shared_pos[128]`), issue a `threadgroup_barrier(mem_flags::mem_threadgroup)`, and reuse the cached data across all threads in the threadgroup.
2. **SIMD register rotation (`simd_shuffle`):**
   Within a SIMD group, rotate coordinate registers across threads using `simd_shuffle_down(val, delta)` and `simd_shuffle_xor(val, mask)`. This allows evaluating all pairwise interactions within a 32-atom block in registers without threadgroup memory writes.
3. **Hardware FP32 atomic additions (Apple 9+ / M3+):**
   On M3, M4, and M5 chips, accumulate pairwise forces directly into device memory using native hardware `atomic_fetch_add_explicit<float>` (`MTL::BarrierScopeBuffers`). This removes the need for separate force reduction kernels or threadgroup mutexes.
4. **Topology exclusion bitsets:**
   Store 1-2, 1-3, and 1-4 bonded exclusions as bitmasks packed in unsigned 32-bit or 64-bit integers. Replace binary searches or pointer indirection with bitwise operations (`(exclusion_mask & (1u << j)) != 0`).

### PME and electrostatics

1. **Real half-spectrum 3D FFT:**
   For reciprocal-space electrostatic potential, evaluate real-to-complex (R2C) and complex-to-real (C2R) transforms. This reduces grid storage and compute operations by 50% compared to full complex-to-complex FFTs ($N_x \times N_y \times [N_z/2 + 1]$).
2. **Direct atomic charge spreading:**
   In PME charge interpolation (`gridSpreadCharge`), interpolate B-spline weights and accumulate fractional charges directly into the 3D grid buffer using native FP32 atomics. On M4 Max, this kernel accounted for 13.5% of OpenCL step time because OpenCL used emulated integer atomics or multi-pass sorting.
3. **Shared bonded and correction force buffers:**
   Accumulate real-space PME exclusion correction forces directly into the bonded force accumulation buffer. Allocating a single scratch buffer eliminates kernel dispatches and device memory round-trips.

### Constraints and integration

1. **Analytical SETTLE for water molecules:**
   Over 80% of atoms in typical biomolecular simulations belong to rigid TIP3P or TIP4P water molecules. Evaluating constraints through an explicit analytical SETTLE kernel in Metal eliminates dozens of iterative SHAKE/RATTLE iterations, reducing total step time by more than 50%.
2. **Speculative admission overlap:**
   Submit coordinate update and displacement monitoring kernels ahead of time. Allow the GPU to verify neighbor-list validity concurrently with force processing.

---

## Mistakes worth avoiding

### 1. Dispatching one command buffer per kernel
The NORPG `Objective-C` branch (`platforms/metal/src/MetalKernel.mm`, lines 1827-1847) implemented kernel execution as:
```objc
id<MTLCommandBuffer> command = [commandQueue commandBuffer];
id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
// bind pipeline and buffers...
[encoder dispatchThreadgroups:... threadsPerThreadgroup:...];
[encoder endEncoding];
queue.submit((__bridge void*) command); // Calls [command commit]
```
Committing a command buffer per kernel forces every dispatch through the Apple Silicon RTKit firmware scheduler via channel ring buffers. With command buffer submission round-trip latency measured at 10-25 µs, an MD timestep executing 25 individual kernels spends 250 to 625 µs in submission overhead alone. For a 10,000-atom system requiring 1 ms of GPU execution, submission overhead wastes 25-60% of runtime. All non-dependent kernels in an MD step must be encoded into a single command buffer using concurrent encoders (`MTL::DispatchTypeConcurrent`) and hardware fences or memory barriers.

### 2. Under-occupying threadgroups with 32 threads
`moleqular` demonstrated that dispatching threadgroups of 32 threads (1 SIMD group) causes catastrophic occupancy starvation. When a single SIMD group stalls on an off-chip memory fetch, the execution core has no other threadgroups to schedule, stalling the ALU pipeline. Apple GPUs require threadgroups of 128 to 256 threads (4 to 8 SIMD groups) to hide memory latency.

### 3. Uncoalesced cell lists without SIMD clustering
In `moleqular` and `metal-sci-kernels`, direct cell lists where each thread iterated through its own 27 neighboring cells produced severe thread divergence. Because neighbor counts varied across cells, threads within the same SIMD group executed divergent loop iterations, stalling the SIMD lanes. Pair evaluation must be organized in fixed tiles (e.g. 8x8 or 32x32) where all threads in a SIMD group read common j-particles.

### 4. Compiling shaders with fast-math enabled
Passing `-ffast-math` to the Metal compiler or using `MathMode::Fast` enables `no-nans-fp-math`. In Metal Shading Language, this causes floating-point comparisons involving NaNs to produce undefined behavior and causes atomic compare-and-swap (CAS) loops to spin infinitely (`fcmp fast ueq` folding). Furthermore, aggressive algebraic re-association in fast-math violates energy conservation in symplectic integrators, leading to systematic energy drift. Offline and JIT Metal pipelines must explicitly pass `-fno-fast-math` and preserve strict IEEE-754 semantics.

### 5. Function approximations without exact force-potential consistency
`moleqular` tested replacing analytical Lennard-Jones evaluation with a 4-FMA Horner polynomial. While arithmetic was faster, computing forces via the polynomial while computing potential energy analytically broke conservative force relationships, causing continuous energy drift over 1,000 steps. In `mlx-atomistic`, a degree-17 polynomial for bounded Ewald forces regressed step latency by 4.75% because the extended ALU dependency chain stalled registers without reducing memory traffic. Analytical formulas with exact derivative relationships must be preserved.

### 6. Avoiding atomics with pure owner-computes algorithms
`mlx-atomistic` tested an owner-computes force algorithm that eliminated atomics by computing all pair interactions redundantly or assigning writes strictly to particle $i$. The resulting duplicate calculations and memory traversals were 2.5x slower than the atomic `fused_half32` implementation. With native hardware FP32 atomics on M3+, atomics are significantly faster than algorithmic workarounds designed for older GPUs.

### 7. Wrapping OpenCL via `cl2Metal`
Philip Turner's `openmm-metal` wrapped OpenCL C kernels and relied on Apple's `cl2Metal` translation driver. This introduced four critical liabilities:
1. Deprecation: Apple deprecated OpenCL in macOS 10.14. The internal `cl2Metal` compiler does not receive modern Metal 3/4 optimizations.
2. Incomplete feature set: OpenCL cannot access native Metal SIMD shuffle intrinsics, SIMD ballots, hardware FP32 atomics, or indirect command buffers.
3. Driver instability: On newer macOS versions, `cl2Metal` suffered runtime compilation crashes on complex OpenMM kernels (`openmm-metal/README.md`, lines 160-210).
4. Portability rejection: Peter Eastman rejected upstreaming `openmm-metal` into OpenMM core because it did not provide a native Metal codebase and depended on Objective-C build scripts.

### 8. Dynamic graph compilation overhead across rebuilds
`mlx-atomistic` attempted to compile the full MD force graph using `mx.compile`. However, because neighbor lists change dynamically, each neighbor rebuild created a new trace closure. The tracing and compilation overhead regressed 750-step JAC wall time by 4.14%. MD pipelines should compile static Metal compute pipeline states once during system initialization and dispatch them with dynamic buffer bindings.

---

## Consequences for an OpenMM Metal platform

To build a first-class, upstreamable, high-performance Metal platform for OpenMM, the implementation should follow eight specific architectural rules derived from this prior art:

### 1. Pure C++20 implementation using `metal-cpp`
Avoid Objective-C runtime syntax (`.mm` files) and Objective-C automatic reference counting (`@autoreleasepool`). Use Apple's official `metal-cpp` header-only library. This enables OpenMM's Metal platform to compile as standard C++ within OpenMM's existing CMake build system without requiring `enable_language(OBJCXX)`. Single-instance static implementation macros (`#define MTL_PRIVATE_IMPLEMENTATION`) should be isolated to a single translation unit (`MetalContext.cpp`), exactly as MLX does.

### 2. Batched command encoding per timestep
Do not commit command buffers on every kernel execution. Group the entire molecular dynamics timestep into one or two `MTL::CommandBuffer` instances:
- Use concurrent compute command encoders (`MTL::DispatchTypeConcurrent`).
- Synchronize dependent kernels (e.g. nonbonded forces following neighbor list construction) using `encoder->memoryBarrier(MTL::BarrierScopeBuffers)` or `MTL::Fence`.
- Commit the command buffer only once per timestep, driving CPU-GPU latency from 500 µs down to below 15 µs.

### 3. Native Metal Shading Language 3.1+ (macOS 14+)
Write all kernels in native MSL targeting Metal 3.1+. Do not translate OpenCL strings at runtime via regex. Native MSL enables:
- 32-wide SIMD operations: `simd_sum`, `simd_prefix_inclusive_sum`, `simd_ballot`, `simd_shuffle_down`.
- Direct hardware atomics: `atomic_fetch_add_explicit<float>`.
- Templated data types and constexpr loop unrolling.

### 4. 32x32 tiled nonbonded force kernels
Align nonbonded interaction tiles to 32 atoms, matching the native hardware SIMD execution width. Launch threadgroups of 128 or 256 threads (4 or 8 SIMD groups) to guarantee full occupancy and latency hiding. Load j-particle positions cooperatively into threadgroup memory and rotate registers using SIMD shuffles.

### 5. Architectural bifurcation for floating-point atomics
- **Apple 9+ (M3, M4, M5):** Use native hardware `atomic_fetch_add_explicit` for single-precision floating-point force accumulation and PME charge spreading.
- **Apple 7/8 (M1, M2):** Emulate FP32 atomics using 64-bit integer fixed-point math (`atomic_fetch_add_explicit<ulong>`) or a 32-bit integer compare-and-swap loop (`atomic_compare_exchange_weak_explicit`). Avoid spinning CAS loops by enforcing `-fno-fast-math`.

### 6. Two-level neighbor list with active SIMD compaction
Adopt a two-level Verlet list with inner and outer bounding skins. Use `simd_ballot` to compact active particle blocks on the fly, eliminating empty pair calculations. Execute neighbor-list displacement checks on the GPU to avoid CPU synchronization stalls.

### 7. Analytical SETTLE for water constraints
Provide a dedicated native Metal kernel for analytical SETTLE water constraints. Because solvent water accounts for 80-90% of constraints in biomolecular simulations, solving them analytically in a single kernel dispatch eliminates iterative constraint latency.

### 8. Real half-spectrum 3D FFT for PME
Implement reciprocal-space PME electrostatics using a real-to-complex (R2C) 3D FFT (via VkFFT or a dedicated Metal FFT kernel) storing $N_x \times N_y \times (N_z/2 + 1)$ complex elements, saving 50% of memory and compute time over full complex transforms.

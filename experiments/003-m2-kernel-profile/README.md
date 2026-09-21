# 003: where the OpenCL platform spends GPU time on a base M2

## Question

peastman profiled apoa1pme on an M4 Max in openmm/openmm#5397. philipturner predicted that findBlocksWithInteractions takes a larger share on older chips and on apoa1rf. Does a base M2 agree?

## Method

- Same machine and OpenMM commit as experiment 001 (M2, 10 GPU cores, macOS 27.0, upstream master 5a7a26861).
- One source change: `#define ENABLE_PROFILING` switched on in `platforms/opencl/src/OpenCLContext.cpp`. This makes the queue a profiling queue and prints one trace event per kernel launch.
- `python benchmark.py --platform OpenCL --test <apoa1rf|apoa1pme> --seconds 15`, stdout captured, summed per kernel name with `profile-kernels.py`.
- The profiling queue stops command batching, so ns/day from these runs means nothing. Only the fractions are used.
- Unit caveat: the summed kernel time is about 0.15 ms per step while a step takes about 4.9 ms of wall time. Apple's OpenCL layer probably reports profiling timestamps in mach ticks (41.67 ns on Apple silicon) and not nanoseconds. Unverified. It does not affect the fractions. FFT kernels come from VkFFT and are not captured, as in peastman's numbers.

## Result

apoa1pme, fraction of captured GPU time:

| Kernel | M2 (this lab) | M4 Max (peastman) |
| --- | --- | --- |
| computeNonbonded | 0.290 | 0.327 |
| findBlocksWithInteractions | 0.251 | 0.236 |
| gridSpreadCharge | 0.081 | 0.135 |
| finishSpreadCharge | 0.069 | 0.0116 |
| computeBondedForces | 0.057 | 0.0826 |
| assignElementsToBuckets | 0.057 | not listed |
| computeRange | 0.045 | 0.0337 |
| gridInterpolateForce | 0.028 | 0.026 |
| sortBuckets | 0.015 | 0.0245 |

apoa1rf on the M2: computeNonbonded 0.428, findBlocksWithInteractions 0.342, computeRange 0.066, computeBondedForces 0.066, everything else under 0.01 each.

## What it changes

- philipturner's prediction holds. On apoa1rf the neighbour search is 34% of GPU time on an M2. If a Metal version with SIMD-group reductions made it free, the ceiling is 1/(1-0.342) = 1.52x, which matches the 1.3x to 1.5x he measured with his plugin. On apoa1pme the same ceiling is 1.34x.
- computeNonbonded plus findBlocksWithInteractions is 54% (pme) to 77% (rf) of GPU time. peastman's call to do NonbondedForce first is right for this chip too.
- Charge spreading behaves differently here: finishSpreadCharge costs 6.9% on the M2 against 1.2% on the M4 Max, and gridSpreadCharge less. The two together are 15% on both chips. finishSpreadCharge converts the fixed-point grid that exists only because OpenCL has no float atomics. The M2 has no float atomics in Metal either (M3 and later only, per philipturner, to be confirmed by docs/metal/msl-for-compute.md), so on this chip a Metal port keeps that cost unless it spreads charge another way.
- assignElementsToBuckets at 5.7% is the sort inside the neighbour list rebuild. Worth a look after the two big kernels.

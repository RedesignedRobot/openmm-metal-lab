# Experiment 015 run

Chip: Apple M3 Pro (Apple M3 Pro), macOS Version 27.0 (Build 26A428), 2026-09-22T23:08:41Z
Compile: MSL 3.1, mathMode = .safe unless a table says otherwise. Command: ./harness accuracy

## 3a. Accuracy of df64 operations against CPU double

1048576 random inputs per row, inputs are exact df64 pairs split from doubles, reference is the same op in CPU double (itself within 2^-53 = 0.03 units).
Error = |gpu - ref| / |ref| in units of 2^-48. Flag threshold 2^-44 = 16 units. Proven bound from the literature in the same units (u = 2^-24, u^2 = 1 unit).

| Operation | Inputs | Median | 99.9th pct | Max | Proven bound | > 2^-44 | Non-finite |
| --- | --- | ---: | ---: | ---: | --- | ---: | ---: |
| df64 + df64 | a, b in +-[1e-4, 1e7] | 0.102 | 1.332 | 2.232 | 3u^2 = 3 | 0 | 0 |
| df64 + df64 (position + step) | a in +-[1e-3, 1e3], b in +-[1e-9, 1e-2] | 0.104 | 1.307 | 2.223 | 3 | 0 | 0 |
| df64 + df64 (cancellation) | b = -a(1+d), d in +-[2^-40, 2^-8] | 0.000 | 0.000 | 0.000 | 3 | 0 | 0 |
| df64 - df64 | a, b in +-[1e-4, 1e7] | 0.102 | 1.337 | 2.246 | 3 | 0 | 0 |
| df64 * df64 | a, b in +-[1e-4, 1e7] | 0.227 | 2.223 | 3.363 | 4u^2 = 4 | 0 | 0 |
| df64 / df64 | a, b in +-[1e-4, 1e7] | 0.275 | 3.498 | 6.801 | 15u^2 = 15 | 0 | 0 |
| df64 + float | a in +-[1e-4, 1e7], b float in +-[1e-4, 1e7] | 0.036 | 0.995 | 1.900 | 2u^2 = 2 | 0 | 0 |
| df64 * float | a in +-[1e-4, 1e7], b float in +-[1e-4, 1e7] | 0.115 | 1.031 | 1.702 | 2 | 0 | 0 |
| df64 / float | a in +-[1e-4, 1e7], b float in +-[1e-4, 1e7] | 0.130 | 1.795 | 2.697 | 3u^2 = 3 | 0 | 0 |
| sqrt(df64) | a in [1e-6, 1e7] | 0.117 | 1.960 | 2.973 | 25/8 u^2 = 3.1 | 0 | 0 |
| exp(df64) | a in [-60, 60] | 0.170 | 1.397 | 2.592 | none proven | 0 | 0 |
| exp(df64), Langevin scale | a in [-0.1, 0] | 0.069 | 0.581 | 0.872 | none proven | 0 | 0 |
| log(df64) | a in [1e-6, 1e7] | 0.102 | 2.604 | 6.410 | none proven | 0 | 0 |
| log(df64) near 1 | a = 1 + d, d in +-[1e-9, 0.5] | 0.509 | 4.372 | 7.548 | none proven | 0 | 0 |
| df64(long), fixed-point force | n in +-[1, 2^62] | 0.000 | 0.471 | 0.500 | 1 rounding of lo | 0 | 0 |
| df64 * long, force scale | a = dt/2^32, dt in [1e-4, 1e-2]; n in +-[1, 2^50] | 0.182 | 2.032 | 3.410 | 4 + conversion | 0 | 0 |

Comparisons (<, <=, ==, >, >=, !=) on 1048576 pairs, 3/5 of them equal or one ulp of lo or hi apart: 0 mismatches against CPU double.
Conversion df64 -> float (the implicit `(real) mixed`): 0 of 1048576 differ from RN(value) bit for bit.

### Float primitives under safe math

Results not correctly rounded, of 4194304 random operands in [1e-10, 1e10]: sqrt 1146376, x / y 0, precise::sqrt 0, precise::divide 0. df64 uses precise::sqrt and `/`.
Subnormals: 2^-140 * 1 = 0.0, 2^-70 * 2^-70 = 0.0 (exact: 7.17e-43), (2^-140 != 0) = false. Zero results mean flush to zero.

### Math mode check

| mathMode | two_sum(1, 2^-30) error term | two_prod(1+2^-12, same) error term | df64 + df64 max | df64 * df64 max | df64 / df64 max | sqrt max |
| --- | --- | --- | ---: | ---: | ---: | ---: |
| safe | 9.313226e-10 (exact: 9.313226e-10) | 5.9604645e-08 (exact: 5.9604645e-08) | 1.99 | 3.15 | 5.25 | 2.74 |
| relaxed | 0.0 (exact: 9.313226e-10) | 5.9604645e-08 (exact: 5.9604645e-08) | 3.26e+07 | 3.29e+07 | 4.13e+07 | 1.67e+07 |
| fast | 0.0 (exact: 9.313226e-10) | 5.9604645e-08 (exact: 5.9604645e-08) | 3.26e+07 | 3.29e+07 | 4.13e+07 | 1.67e+07 |

## 3b. IEEE double <-> df64 conversion kernels (df64FromIEEE, df64ToIEEE, in place)

| Input | Bits | GPU hi | GPU lo | Decode matches reference | Encode(decode(x)) | Round trip |
| --- | --- | --- | --- | --- | --- | --- |
| +0 | 0x0 | 0.0 | 0.0 | yes | matches RN(hi+lo) | exact |
| -0 | 0x8000000000000000 | -0.0 | 0.0 | yes | matches RN(hi+lo) | exact |
| +inf | 0x7ff0000000000000 | inf | 0.0 | yes | matches RN(hi+lo) | exact |
| -inf | 0xfff0000000000000 | -inf | 0.0 | yes | matches RN(hi+lo) | exact |
| quiet NaN | 0x7ff8000000000000 | nan | 0.0 | yes | matches RN(hi+lo) | exact |
| -quiet NaN | 0xfff8000000000000 | nan | 0.0 | yes | matches RN(hi+lo) | exact |
| signaling NaN | 0x7ff4000000000000 | nan | 0.0 | yes | matches RN(hi+lo) | exact |
| NaN with payload | 0x7ff00000deadbeef | nan | 0.0 | yes | matches RN(hi+lo) | exact |
| smallest subnormal double | 0x1 | 0.0 | 0.0 | yes | matches RN(hi+lo) | rel 1.0e+00 (not representable) |
| -largest subnormal double | 0x800fffffffffffff | -0.0 | -0.0 | yes | matches RN(hi+lo) | rel 1.0e+00 (not representable) |
| smallest normal double | 0x10000000000000 | 0.0 | 0.0 | yes | matches RN(hi+lo) | rel 1.0e+00 (not representable) |
| 2^-151 | 0x3680000000000000 | 0.0 | 0.0 | yes | matches RN(hi+lo) | rel 1.0e+00 (not representable) |
| 2^-150 (tie to 0) | 0x3690000000000000 | 0.0 | 0.0 | yes | matches RN(hi+lo) | rel 1.0e+00 (not representable) |
| 2^-150 + tiny (to 2^-149) | 0x3690000000000001 | 1e-45 | -0.0 | yes | matches RN(hi+lo) | rel 1.0e+00 (not representable) |
| 2^-149 | 0x36a0000000000000 | 1e-45 | 0.0 | yes | matches RN(hi+lo) | exact |
| -3 * 2^-150 (tie to even) | 0xb6a8000000000000 | -3e-45 | 0.0 | yes | matches RN(hi+lo) | rel 3.3e-01 (not representable) |
| 2^-127 + 2^-140 | 0x3800008000000000 | 5.878189e-39 | 0.0 | yes | matches RN(hi+lo) | exact |
| 2^-126 | 0x3810000000000000 | 1.1754944e-38 | 0.0 | yes | matches RN(hi+lo) | exact |
| 2^-75 (slow path edge) | 0x3b43c0ca428c58fc | 3.267874e-23 | 2.5127515e-31 | yes | matches RN(hi+lo) | exact |
| 2^-74 (fast path edge) | 0x3b53c0ca428c58fc | 6.535748e-23 | 5.025503e-31 | yes | matches RN(hi+lo) | exact |
| 2^-102 (lo leaves normal range) | 0x3993c0ca428c58fc | 2.4347558e-31 | 1.872146e-39 | yes | matches RN(hi+lo) | rel 7.2e-16 (not representable) |
| 1 | 0x3ff0000000000000 | 1.0 | 0.0 | yes | matches RN(hi+lo) | exact |
| -1 | 0xbff0000000000000 | -1.0 | 0.0 | yes | matches RN(hi+lo) | exact |
| 1 + 2^-24 (tie, even) | 0x3ff0000010000000 | 1.0 | 5.9604645e-08 | yes | matches RN(hi+lo) | exact |
| 1 + 3*2^-24 (tie, odd) | 0x3ff0000030000000 | 1.0000002 | -5.9604645e-08 | yes | matches RN(hi+lo) | exact |
| 1 + 2^-24 + 2^-52 | 0x3ff0000010000001 | 1.0000001 | -5.9604645e-08 | yes | matches RN(hi+lo) | rel 2.2e-16 (not representable) |
| 1 - 2^-53 | 0x3fefffffffffffff | 1.0 | -1.110223e-16 | yes | matches RN(hi+lo) | exact |
| 1 + 2^-52 | 0x3ff0000000000001 | 1.0 | 2.220446e-16 | yes | matches RN(hi+lo) | exact |
| pi | 0x400921fb54442d18 | 3.1415927 | -8.742278e-08 | yes | matches RN(hi+lo) | rel 1.1e-15 (not representable) |
| -1e7 / 3 | 0xc1496e6aaaaaaaab | -3333333.2 | -0.083333336 | yes | matches RN(hi+lo) | rel 7.0e-16 (not representable) |
| 0.002 | 0x3f60624dd2f1a9fc | 0.002 | -9.49949e-11 | yes | matches RN(hi+lo) | rel 8.7e-16 (not representable) |
| 2^32 | 0x41f0000000000000 | 4.2949673e+09 | 0.0 | yes | matches RN(hi+lo) | exact |
| FLT_MAX | 0x47efffffe0000000 | 3.4028235e+38 | 0.0 | yes | matches RN(hi+lo) | exact |
| FLT_MAX + half ulp - 2^76 (below tie) | 0x47efffffeffffffe | 3.4028235e+38 | 1.0141205e+31 | yes | matches RN(hi+lo) | rel 2.2e-16 (not representable) |
| FLT_MAX + half ulp (tie to inf) | 0x47effffff0000000 | inf | 0.0 | yes | matches RN(hi+lo) | inf |
| 2^128 | 0x47f0000000000000 | inf | 0.0 | yes | matches RN(hi+lo) | inf |
| -2^200 | 0xcc70000000000000 | -inf | 0.0 | yes | matches RN(hi+lo) | inf |
| DBL_MAX | 0x7fefffffffffffff | inf | 0.0 | yes | matches RN(hi+lo) | inf |
| 2^127 * (2 - 2^-30) | 0x47efffffffc00000 | inf | 0.0 | yes | matches RN(hi+lo) | inf |

Special cases failing any check: 0 of 39.

| Set | Doubles | Decode bit-exact | Encode(decode) = RN(hi+lo) bit-exact | Representable | Representable round trips exact | Decode idempotent after encode |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| uniform random 64-bit patterns (all exponents, NaN, inf, subnormal) | 1048576 | 1048576 | 1048576 | 481314 | 481314 | 817957 |
| random doubles, exponent uniform in [-160, 140], random sign | 1048576 | 1048576 | 1048576 | 244295 | 244295 | 984079 |
| MD magnitudes, +-[1e-4, 1e7] | 1048576 | 1048576 | 1048576 | 196516 | 196516 | 1048576 |

Representable: the double equals hi + lo exactly (its bits fit in two floats), or it is NaN or overflows float. For those a round trip must return the input (inf for values beyond float range, NaN for NaN).

Encode of 1048576 random pairs over the float range (a quarter of them unnormalized, |lo| up to 4 ulp(hi)): 1048576 bit-exact against RN(hi + lo).

## 3c. Compile census: Common kernels that mention mixed precision

OpenMM commit 3c9effc96d0c89cc7bfc8154eb9122a618061d8f, 67 kernel files, 36 mention `mixed` (case-insensitive, so USE_MIXED_PRECISION counts).
Program = lab prelude (005) with its precision block replaced + defines from 002 + the 005 rewrites. Mixed mode defines USE_MIXED_PRECISION and SUPPORTS_DOUBLE_PRECISION as OpenCLContext does, with `double` mapped to df64.

| File | single | df64 pairs | df64 IEEE | df64 without SUPPORTS_DOUBLE_PRECISION | df64 pairs + Common edits | df64 errors not in single | First df64 error |
| --- | --- | --- | --- | --- | --- | ---: | --- |
| andersenThermostat.cc | ok | ok | ok | ok | (no edit) ok | 0 |  |
| atmforce.cc | ok | ok | ok | ok | (no edit) ok | 0 |  |
| brownian.cc | ok | ok | ok | ok | (no edit) ok | 0 |  |
| constantPotential.cc | ok | ok | ok | ok | (no edit) ok | 0 |  |
| constantPotentialCGSolver.cc | ok | ok | ok | ok | (no edit) ok | 0 |  |
| constraints.cc | ok | ok | ok | ok | (no edit) ok | 0 |  |
| customCVForce.cc | ok | ok | ok | ok | (no edit) ok | 0 |  |
| customCentroidBond.cc | ok | ok | ok | ok | (no edit) ok | 0 |  |
| customGBEnergyN2.cc | ok | ok | ok | ok | (no edit) ok | 0 |  |
| customGBEnergyN2_cpu.cc | ok | ok | ok | ok | (no edit) ok | 0 |  |
| customGBEnergyPerParticle.cc | ok | ok | ok | ok | (no edit) ok | 0 |  |
| customHbondForce.cc | ok | ok | ok | ok | (no edit) ok | 0 |  |
| customIntegrator.cc | ok | ok | ok | ok | (no edit) ok | 0 |  |
| customIntegratorPerDof.cc | ok | ok | ok | FAIL | (no edit) ok | 0 | error: functional-style cast from 'const device df64' to 'float3' (vector of 3 'float' values) is not allowed |
| customManyParticle.cc | ok | ok | ok | ok | (no edit) ok | 0 |  |
| customNonbondedGroups.cc | ok | ok | ok | ok | (no edit) ok | 0 |  |
| dpd.cc | FAIL | FAIL | FAIL | FAIL | (no edit) FAIL | 0 | error: pointer type must have explicit address space qualifier |
| ewald.cc | ok | ok | ok | ok | (no edit) ok | 0 |  |
| gayBerne.cc | FAIL | FAIL | FAIL | FAIL | (no edit) FAIL | 0 | error: pointer type must have explicit address space qualifier |
| gbsaObc.cc | ok | ok | ok | ok | (no edit) ok | 0 |  |
| gbsaObcReductions.cc | ok | ok | ok | ok | (no edit) ok | 0 |  |
| gbsaObc_cpu.cc | ok | ok | ok | ok | (no edit) ok | 0 |  |
| integrationUtilities.cc | ok | FAIL | FAIL | FAIL | ok | 1 | error: conditional expression is ambiguous; 'df64' can be converted to 'float' and vice versa |
| langevinMiddle.cc | ok | ok | ok | ok | (no edit) ok | 0 |  |
| lcpo.cc | ok | ok | ok | ok | (no edit) ok | 0 |  |
| minimize.cc | ok | FAIL | FAIL | FAIL | (no edit) FAIL | 1 | error: call to deleted function 'atomicAdd' |
| monteCarloBarostat.cc | ok | ok | ok | ok | (no edit) ok | 0 |  |
| nonbondedParameters.cc | ok | ok | ok | ok | (no edit) ok | 0 |  |
| noseHooverChain.cc | ok | ok | ok | ok | (no edit) ok | 0 |  |
| noseHooverIntegrator.cc | ok | FAIL | FAIL | FAIL | ok | 2 | error: conditional expression is ambiguous; 'float' can be converted to 'df64' and vice versa |
| pme.cc | ok | ok | ok | ok | (no edit) ok | 0 |  |
| qtb.cc | ok | ok | ok | ok | (no edit) ok | 0 |  |
| removeCM.cc | ok | ok | ok | ok | (no edit) ok | 0 |  |
| rg.cc | ok | ok | ok | ok | (no edit) ok | 0 |  |
| utilities.cc | ok | ok | ok | ok | (no edit) ok | 0 |  |
| verlet.cc | ok | ok | ok | ok | (no edit) ok | 0 |  |
| **compiled** | 34/36 | 31/36 | 31/36 | 30/36 | 33/36 | | |

## 3d. Cost of df64 in Common integration kernels

Build processes before timing (pgrep ninja|clang|cc1plus): none

Clock: GPU, MTLCommandBuffer gpuEndTime - gpuStartTime, one compute encoder per command buffer holding 200 repetitions, median of 5 command buffers after one warm-up. One thread per atom, 64-thread threadgroups. Kernels are the unmodified Common sources through the lab prelude and the 005 rewrites.

### One Verlet step against CPU double (23,558 atoms)

Errors are normwise: max |gpu - ref| over all components divided by max |ref|.

| Mode | velocity error | position error (posq + posqCorrection) | max difference from pair storage, velocity |
| --- | ---: | ---: | ---: |
| single (float mixed) | 1.01e-07 | 4.77e-08 |  |
| df64 mixed, pair storage | 1.08e-14 | 1.42e-15 |  |
| df64 mixed, IEEE storage | 1.08e-14 | 1.42e-15 | 6.15e-16 |

### Time per call, µs (GPU clock)

| Integrator | Kernel | Atoms | single | df64 pairs | df64 IEEE | pairs / single | IEEE / single |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Verlet | integrateVerletPart1 | 23558 | 6.7 | 9.7 | 17.5 | 1.46 | 2.62 |
| Verlet | integrateVerletPart2 | 23558 | 4.3 | 6.5 | 13.5 | 1.51 | 3.16 |
| Verlet | whole step | 23558 | 8.9 | 16.4 | 34.0 | 1.85 | 3.84 |
| LangevinMiddle | integrateLangevinMiddlePart1 | 23558 | 4.1 | 8.0 | 13.2 | 1.97 | 3.22 |
| LangevinMiddle | integrateLangevinMiddlePart2 | 23558 | 5.1 | 8.7 | 20.4 | 1.71 | 4.02 |
| LangevinMiddle | integrateLangevinMiddlePart3 | 23558 | 5.0 | 8.8 | 15.9 | 1.77 | 3.21 |
| LangevinMiddle | whole step | 23558 | 12.6 | 24.8 | 52.3 | 1.97 | 4.16 |
| Verlet | integrateVerletPart1 | 173112 | 83.8 | 158.6 | 185.8 | 1.89 | 2.22 |
| Verlet | integrateVerletPart2 | 173112 | 47.2 | 199.7 | 216.2 | 4.23 | 4.58 |
| Verlet | whole step | 173112 | 133.6 | 367.4 | 414.1 | 2.75 | 3.10 |
| LangevinMiddle | integrateLangevinMiddlePart1 | 173112 | 30.7 | 84.1 | 76.4 | 2.74 | 2.48 |
| LangevinMiddle | integrateLangevinMiddlePart2 | 173112 | 49.8 | 156.3 | 206.9 | 3.14 | 4.16 |
| LangevinMiddle | integrateLangevinMiddlePart3 | 173112 | 82.9 | 294.6 | 278.9 | 3.55 | 3.36 |
| LangevinMiddle | whole step | 173112 | 228.2 | 554.6 | 619.2 | 2.43 | 2.71 |

### Bulk conversion of a velm-sized array (4 doubles per atom), µs (GPU clock)

| Atoms | Doubles | df64FromIEEE | df64ToIEEE |
| ---: | ---: | ---: | ---: |
| 23558 | 94232 | 8.2 | 8.0 |
| 173112 | 692448 | 38.8 | 38.7 |

Build processes after timing: none. Timing is uncontended.


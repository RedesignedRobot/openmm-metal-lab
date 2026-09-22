# Experiment 015 run

Chip: Apple M3 Pro (Apple M3 Pro), macOS Version 27.0 (Build 26A428), 2026-09-22T23:34:34Z
Compile: MSL 3.1, mathMode = .safe unless a table says otherwise. Command: ./harness accuracy

## 3a. Accuracy of df64 operations against CPU double

1048576 random inputs per row, inputs are double-word pairs split from doubles by the decode rule, reference is the same op in CPU double on the exact pair values (itself within 2^-53 = 0.03 units).
Error = |gpu - ref| / |ref| in units of 2^-48. Flag threshold 2^-44 = 16 units. Proven bound in the same units (u = 2^-24, u^2 = 1 unit): JMP = Joldes, Muller, Popescu, ACM TOMS 44(2) 2017; MR = Muller, Rideau, ACM TOMS 48(1) 2022; sqrt: Lefevre et al., ACM TOMS 2023.

| Operation | Inputs | Median | 99.9th pct | Max | Proven bound | > 2^-44 | Non-finite |
| --- | --- | ---: | ---: | ---: | --- | ---: | ---: |
| df64 + df64 | a, b in +-[1e-4, 1e7] | 0.102 | 1.332 | 2.232 | 3u^2 + 13u^3 = 3 (JMP Thm 3.1) | 0 | 0 |
| df64 + df64 (position + step) | a in +-[1e-3, 1e3], b in +-[1e-9, 1e-2] | 0.104 | 1.307 | 2.223 | 3 | 0 | 0 |
| df64 + df64 (cancellation) | b = -a(1+d), d in +-[2^-40, 2^-8] | 0.000 | 0.000 | 0.000 | 3 | 0 | 0 |
| df64 - df64 | a, b in +-[1e-4, 1e7] | 0.102 | 1.337 | 2.246 | 3 | 0 | 0 |
| df64 * df64 | a, b in +-[1e-4, 1e7] | 0.227 | 2.223 | 3.363 | 4u^2 = 4 (MR Thm 2.8) | 0 | 0 |
| df64 / df64 | a, b in +-[1e-4, 1e7] | 0.296 | 3.543 | 6.801 | 15u^2 + 56u^3 = 15 (JMP Thm 7.1) | 0 | 0 |
| df64 + float | a in +-[1e-4, 1e7], b float in +-[1e-4, 1e7] | 0.036 | 0.995 | 1.900 | 2u^2 = 2 (JMP Thm 2.2) | 0 | 0 |
| df64 * float | a in +-[1e-4, 1e7], b float in +-[1e-4, 1e7] | 0.115 | 1.031 | 1.702 | 2u^2 = 2 (JMP Thm 4.3) | 0 | 0 |
| df64 / float | a in +-[1e-4, 1e7], b float in +-[1e-4, 1e7] | 0.130 | 1.795 | 2.697 | 3u^2 = 3 (JMP Thm 6.2) | 0 | 0 |
| sqrt(df64) | a in [1e-6, 1e7] | 0.117 | 1.960 | 2.973 | 25/8 u^2 = 3.1 | 0 | 0 |
| exp(df64) | a in [-60, 60] | 0.170 | 1.397 | 2.592 | none proven | 0 | 0 |
| exp(df64), Langevin scale | a in [-0.1, 0] | 0.069 | 0.581 | 0.872 | none proven | 0 | 0 |
| log(df64) | a in [1e-6, 1e7] | 0.102 | 2.604 | 6.410 | none proven | 0 | 0 |
| log(df64) near 1 | a = 1 + d, d in +-[1e-9, 0.5] | 0.509 | 4.372 | 7.548 | none proven | 0 | 0 |
| df64(long), fixed-point force | n in +-[1, 2^62] | 0.000 | 0.471 | 0.500 | 1 rounding of lo | 0 | 0 |
| df64 * long, force scale | a = dt/2^32, dt in [1e-4, 1e-2]; n in +-[1, 2^50] | 0.182 | 2.032 | 3.410 | 4 + conversion | 0 | 0 |

Operands decoded on the GPU (df64_from_ieee) from 1048576 doubles in +-[1e-4, 1e7], half of them within 32 double ulps of a float tie of an odd hi; the second operand is the same double, a neighbouring double or float, or unrelated:

- Decoded pairs that are not double-word numbers (hi != RN(hi + lo)): 0. Decoded pairs that differ from the CPU split: 0.
- Comparisons (<, <=, ==, >, >=, !=) that disagree with exact comparison of the decoded values: 0.
- `(float) x` (the implicit `(real) mixed`) differing from RN(d) of the source double, bit for bit: 0.
- Pairs where x + 0, x + 0.0f, x * 1.0f or x * df64(1) is not the same pair: 0.

### Float primitives under safe math

Results not correctly rounded, of 4194304 random operands in [1e-10, 1e10]: sqrt 1146376, x / y 0, precise::sqrt 0, precise::divide 0. df64 uses precise::sqrt and `/`.
Subnormals: 2^-140 * 1 = 0.0, 2^-70 * 2^-70 = 0.0 (exact: 7.17e-43), (2^-140 != 0) = false. Zero results mean flush to zero.

### Math mode check

| mathMode | two_sum(1, 2^-30) error term | two_prod(1+2^-12, same) error term | df64 + df64 max | df64 * df64 max | df64 / df64 max | sqrt max |
| --- | --- | --- | ---: | ---: | ---: | ---: |
| safe | 9.313226e-10 (exact: 9.313226e-10) | 5.9604645e-08 (exact: 5.9604645e-08) | 1.99 | 3.15 | 5.97 | 2.74 |
| relaxed | 0.0 (exact: 9.313226e-10) | 5.9604645e-08 (exact: 5.9604645e-08) | 3.26e+07 | 3.29e+07 | 3.15e+07 | 1.67e+07 |
| fast | 0.0 (exact: 9.313226e-10) | 5.9604645e-08 (exact: 5.9604645e-08) | 3.26e+07 | 3.29e+07 | 3.15e+07 | 1.67e+07 |

## 3b. IEEE double <-> df64 conversion kernels (df64FromIEEE, df64ToIEEE, in place)

Decode reference: hi = RN(d), lo = RN(d - hi) moved one float towards zero when it is half an ulp of an odd hi; the decoded pair must also be a double-word number (hi = RN(hi + lo)).

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
| 1 + 2^-24 + 2^-52 | 0x3ff0000010000001 | 1.0000001 | -5.960464e-08 | yes | matches RN(hi+lo) | rel 3.3e-15 (not representable) |
| 1 - 2^-53 | 0x3fefffffffffffff | 1.0 | -1.110223e-16 | yes | matches RN(hi+lo) | exact |
| 1 + 2^-52 | 0x3ff0000000000001 | 1.0 | 2.220446e-16 | yes | matches RN(hi+lo) | exact |
| 1 + 2^-23 + 2^-24 - 2^-52 (below a tie, odd hi) | 0x3ff000002fffffff | 1.0000001 | 5.960464e-08 | yes | matches RN(hi+lo) | rel 3.3e-15 (not representable) |
| -(1 + 2^-23) + 2^-24 + 2^-52 (below a tie, odd hi) | 0xbff000000fffffff | -1.0 | -5.9604645e-08 | yes | matches RN(hi+lo) | rel 2.2e-16 (not representable) |
| 2^-110 (1 + 2^-23) + 2^-134 - 2^-162 (below a tie, subnormal lo) | 0x391000002fffffff | 7.703721e-34 | 4.5916e-41 | yes | matches RN(hi+lo) | rel 1.8e-12 (not representable) |
| pi | 0x400921fb54442d18 | 3.1415927 | -8.742278e-08 | yes | matches RN(hi+lo) | rel 1.1e-15 (not representable) |
| -1e7 / 3 | 0xc1496e6aaaaaaaab | -3333333.2 | -0.083333336 | yes | matches RN(hi+lo) | rel 7.0e-16 (not representable) |
| 0.002 | 0x3f60624dd2f1a9fc | 0.002 | -9.49949e-11 | yes | matches RN(hi+lo) | rel 8.7e-16 (not representable) |
| 2^32 | 0x41f0000000000000 | 4.2949673e+09 | 0.0 | yes | matches RN(hi+lo) | exact |
| FLT_MAX | 0x47efffffe0000000 | 3.4028235e+38 | 0.0 | yes | matches RN(hi+lo) | exact |
| FLT_MAX + half ulp - 2^76 (below tie) | 0x47efffffeffffffe | 3.4028235e+38 | 1.0141204e+31 | yes | matches RN(hi+lo) | rel 1.6e-15 (not representable) |
| FLT_MAX + half ulp (tie to inf) | 0x47effffff0000000 | inf | 0.0 | yes | matches RN(hi+lo) | inf |
| 2^128 | 0x47f0000000000000 | inf | 0.0 | yes | matches RN(hi+lo) | inf |
| -2^200 | 0xcc70000000000000 | -inf | 0.0 | yes | matches RN(hi+lo) | inf |
| DBL_MAX | 0x7fefffffffffffff | inf | 0.0 | yes | matches RN(hi+lo) | inf |
| 2^127 * (2 - 2^-30) | 0x47efffffffc00000 | inf | 0.0 | yes | matches RN(hi+lo) | inf |

Special cases failing any check: 0 of 42.

| Set | Doubles | Decode bit-exact | Decoded double-word pairs | Encode(decode) = RN(hi+lo) bit-exact | Representable | Representable round trips exact | Decode idempotent after encode (a zero lo may change sign) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| uniform random 64-bit patterns (all exponents, NaN, inf, subnormal) | 1048576 | 1048576 | 1048576 | 1048576 | 481314 | 481314 | 1048576 |
| random doubles, exponent uniform in [-160, 140], random sign | 1048576 | 1048576 | 1048576 | 1048576 | 244295 | 244295 | 1048576 |
| MD magnitudes, +-[1e-4, 1e7] | 1048576 | 1048576 | 1048576 | 1048576 | 196516 | 196516 | 1048576 |
| within 32 double ulps of a float tie, odd hi, exponents -140..127 | 1048576 | 1048576 | 1048576 | 1048576 | 57334 | 57334 | 1048576 |

Representable: the double equals hi + lo exactly (its bits fit in two floats), or it is NaN or overflows float. For those a round trip must return the input (inf for values beyond float range, NaN for NaN).

| Pair (hi, lo) | GPU encode | RN(hi + lo) | Match |
| --- | --- | --- | --- |
| (FLT_MAX, 2^126) | 4.253529383687635e+38 | 4.253529383687635e+38 | yes |
| (-FLT_MAX, -2^126) | -4.253529383687635e+38 | -4.253529383687635e+38 | yes |
| (1.9 * 2^127, 0.2 * 2^127) | 3.572964817175637e+38 | 3.572964817175637e+38 | yes |
| (FLT_MAX, 2^104 (1 + 2^-23)) | 3.402823669209409e+38 | 3.402823669209409e+38 | yes |
| (FLT_MAX, 2^103) | 3.4028235677973366e+38 | 3.4028235677973366e+38 | yes |
| (FLT_MAX, -FLT_MAX) | 0.0 | 0.0 | yes |
| (0, 2^-10) | 0.0009765625 | 0.0009765625 | yes |
| (-0, 2^-10) | 0.0009765625 | 0.0009765625 | yes |
| (0, 2^-140) | 7.174648137343064e-43 | 7.174648137343064e-43 | yes |
| (-0, +0) | -0.0 | -0.0 | yes |
| (1, NaN) | nan | nan | yes |
| (1, inf) | inf | inf | yes |
| (1, -inf) | -inf | -inf | yes |
| (inf, 1) | inf | inf | yes |
| (2^-120, 2^-140) | 7.523171019910777e-37 | 7.523171019910777e-37 | yes |
| (1, -2^-25) | 0.9999999701976776 | 0.9999999701976776 | yes |

Edge pairs failing: 0 of 16.

| Random pairs, hi over all finite floats | Pairs | Encode = RN(hi + lo) bit-exact |
| --- | ---: | ---: |
| double-word pairs | 262144 | 262144 |
| unnormalized, |lo| up to 4 ulp(hi) | 262144 | 262144 |
| unnormalized, |lo| / |hi| log-uniform in [2^-60, 1] | 262144 | 262144 |
| |hi| >= 2^126, |lo| / |hi| log-uniform in [2^-30, 1] | 262144 | 262144 |

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

Clock: GPU, MTLCommandBuffer gpuEndTime - gpuStartTime, one compute encoder per command buffer. One thread per atom, 64-thread threadgroups. Kernels are the unmodified Common sources through the lab prelude and the 005 rewrites. Variants: single (real = mixed = float, no USE_MIXED_PRECISION); float mixed (USE_MIXED_PRECISION with mixed = float, so posqCorrection is read and written; no SUPPORTS_DOUBLE_PRECISION); df64 pairs and df64 IEEE (USE_MIXED_PRECISION and SUPPORTS_DOUBLE_PRECISION, mixed = df64).

### One Verlet step against CPU double (23,558 atoms)

Errors are normwise: max |gpu - ref| over all components divided by max |ref|.

| Mode | velocity error | position error (posq + posqCorrection) | max difference from pair storage, velocity |
| --- | ---: | ---: | ---: |
| single (no USE_MIXED_PRECISION) | 1.01e-07 | 4.77e-08 |  |
| float mixed (USE_MIXED_PRECISION, mixed = float) | 1.01e-07 | 4.77e-08 |  |
| df64 mixed, pair storage | 1.08e-14 | 1.42e-15 |  |
| df64 mixed, IEEE storage | 1.08e-14 | 1.42e-15 | 6.15e-16 |

### Time per call, µs (GPU clock)

Each cell is the median over 21 rounds, with the interquartile range in brackets. A round measures every (variant, kernel) cell of one integrator and size once, as one command buffer of 200 repetitions, in a freshly shuffled order; one untimed round warms up first. Ratios are of medians, against float mixed.

| Integrator | Kernel | Atoms | single | float mixed | df64 pairs | df64 IEEE | pairs / float mixed | IEEE / float mixed |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Verlet | integrateVerletPart1 | 23558 | 5.0 [4.7-5.1] | 4.9 [4.7-5.1] | 9.5 [9.1-9.6] | 19.9 [19.7-20.2] | 1.93 | 4.01 |
| Verlet | integrateVerletPart2 | 23558 | 4.3 [4.3-4.4] | 5.6 [5.5-5.6] | 6.8 [6.5-7.3] | 16.2 [16.0-16.4] | 1.22 | 2.92 |
| Verlet | whole step | 23558 | 9.0 [8.8-9.3] | 10.8 [10.5-11.0] | 16.8 [16.6-17.0] | 36.6 [36.0-36.8] | 1.56 | 3.40 |
| LangevinMiddle | integrateLangevinMiddlePart1 | 23558 | 4.2 [4.1-4.2] | 4.2 [4.1-4.2] | 8.3 [8.2-8.3] | 16.3 [16.1-16.4] | 1.98 | 3.90 |
| LangevinMiddle | integrateLangevinMiddlePart2 | 23558 | 5.1 [5.0-5.4] | 5.2 [5.1-5.3] | 8.8 [8.7-8.9] | 22.0 [21.5-22.3] | 1.69 | 4.23 |
| LangevinMiddle | integrateLangevinMiddlePart3 | 23558 | 5.2 [4.8-5.3] | 5.7 [5.6-5.8] | 9.0 [8.8-9.1] | 18.0 [17.7-18.0] | 1.59 | 3.17 |
| LangevinMiddle | whole step | 23558 | 13.3 [13.1-13.8] | 15.5 [14.8-16.1] | 26.0 [25.6-26.1] | 57.2 [56.3-57.8] | 1.68 | 3.70 |
| Verlet | integrateVerletPart1 | 173112 | 82.5 [82.1-83.3] | 83.9 [83.4-84.7] | 154.4 [153.8-155.1] | 185.0 [181.8-185.7] | 1.84 | 2.21 |
| Verlet | integrateVerletPart2 | 173112 | 47.3 [47.0-47.5] | 97.7 [96.7-99.1] | 195.9 [195.0-197.4] | 209.7 [208.3-210.8] | 2.00 | 2.15 |
| Verlet | whole step | 173112 | 131.0 [130.4-131.3] | 201.2 [200.4-202.3] | 354.4 [353.6-356.1] | 424.4 [419.0-426.7] | 1.76 | 2.11 |
| LangevinMiddle | integrateLangevinMiddlePart1 | 173112 | 31.3 [31.2-31.4] | 30.9 [30.7-31.0] | 80.6 [80.1-81.0] | 79.3 [79.0-79.5] | 2.61 | 2.57 |
| LangevinMiddle | integrateLangevinMiddlePart2 | 173112 | 55.2 [54.6-55.6] | 53.8 [53.7-54.4] | 150.6 [149.9-151.2] | 202.1 [199.2-203.4] | 2.80 | 3.76 |
| LangevinMiddle | integrateLangevinMiddlePart3 | 173112 | 82.8 [82.3-83.1] | 141.6 [141.0-143.1] | 275.8 [274.8-277.3] | 276.7 [275.2-279.1] | 1.95 | 1.95 |
| LangevinMiddle | whole step | 173112 | 225.7 [224.6-226.1] | 278.6 [277.1-279.3] | 533.7 [532.7-535.2] | 629.8 [628.3-632.6] | 1.92 | 2.26 |

Whole step against the sum of its kernels timed alone (median / sum of medians). A kernel repeated alone rereads the same arrays; a ratio above 1 is consistent with more of them staying in the GPU caches than when the step's kernels alternate (cache residency is not measured here). The whole-step row is the figure to use.

| Integrator | Atoms | single | float mixed | df64 pairs | df64 IEEE |
| --- | ---: | ---: | ---: | ---: | ---: |
| Verlet | 23558 | 0.98 | 1.03 | 1.03 | 1.01 |
| LangevinMiddle | 23558 | 0.92 | 1.03 | 1.00 | 1.02 |
| Verlet | 173112 | 1.01 | 1.11 | 1.01 | 1.08 |
| LangevinMiddle | 173112 | 1.33 | 1.23 | 1.05 | 1.13 |

### Bulk conversion of a velm-sized array (4 doubles per atom), µs (GPU clock)

Median [interquartile range] of 21 command buffers of 200 in-place conversions each, after one warm-up.

| Atoms | Doubles | df64FromIEEE | df64ToIEEE |
| ---: | ---: | ---: | ---: |
| 23558 | 94232 | 6.1 [6.1-6.1] | 7.9 [7.8-7.9] |
| 173112 | 692448 | 39.0 [38.9-39.2] | 38.9 [38.4-39.0] |

Build processes after timing: none. Timing is uncontended.


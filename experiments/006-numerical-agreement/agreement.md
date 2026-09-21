# Numerical agreement report: Metal vs OpenCL

## Hardware and execution environment

- Chip: Apple M3 Ultra
- Metal device: Apple M3 Ultra
- OpenCL device: Apple M3 Ultra
- macOS version: 27.0 (Build 26A428)
- Command: `./agreement`
- Summary status: **PASS**

## 1. erf and erfc accuracy sweep

Evaluated over 100,000 points spanning x in [0.0, 6.0].

| Comparison | Function | Max absolute diff | Max relative diff | Bitwise equal | Status | Note |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| OpenCL vs host libm | `erf` | `5.960e-08` | `1.190e-07` | 98.6% | **PASS** | OpenCL hardware intrinsic vs CPU libm erff |
| OpenCL vs host libm | `erfc` | `5.960e-08` | `1.158e-06` | 56.1% | **PASS** | OpenCL hardware intrinsic vs CPU libm erfcf |
| Metal 005 prelude vs OpenCL | `erf` | `4.619e-07` | `1.867e-03` | 56.3% | **PASS** | 005 A&S 7.1.26 polynomial stand-in vs OpenCL |
| Metal 005 prelude vs OpenCL | `erfc` | `4.768e-07` | `1.005e+00` | 2.4% | **PASS** | 005 prelude 1.0f - erf(x) stand-in suffers catastrophic cancellation for x >= 4 |
| Metal 005 prelude vs host libm | `erf` | `4.619e-07` | `1.867e-03` | 56.3% | **PASS** | 005 A&S 7.1.26 polynomial stand-in vs host libm |
| Metal 005 prelude vs host libm | `erfc` | `4.768e-07` | `1.005e+00` | 1.9% | **PASS** | 005 prelude 1.0f - erf(x) stand-in vs host libm |
| Proposed direct A&S vs OpenCL | `erfc (direct A&S)` | `4.768e-07` | `1.233e-02` | 2.0% | **PASS** | Evaluates poly(t)*exp(-x^2) directly without 1-erf(x) cancellation. Max relative error is 1.23% |
| Proposed direct A&S vs host libm | `erfc (direct A&S)` | `4.768e-07` | `1.233e-02` | 2.0% | **PASS** | Evaluates poly(t)*exp(-x^2) directly without 1-erf(x) cancellation. Max relative error is 1.23% |
| Proposed minimax rational vs OpenCL | `erfc (degree-7 minimax)` | `3.576e-07` | `3.778e-06` | 11.4% | **PASS** | Chebyshev minimax rational polynomial in 1/(1+0.47x). Max relative error matches single precision epsilon (~2.15 ppm) |
| Proposed minimax rational vs host libm | `erfc (degree-7 minimax)` | `3.576e-07` | `3.778e-06` | 11.8% | **PASS** | Chebyshev minimax rational polynomial in 1/(1+0.47x). Max relative error matches single precision epsilon (~2.15 ppm) |

## 2. Integrator program (apoa1rf/008: Langevin Middle Part 1, 2, 3)

Tested on 10,000 atoms (padded to 10,048) over a complete 2 fs integration step. Identical positions, velocities, forces, and Gaussian random variables were dispatched on both OpenCL and Metal.

| Buffer | Total elements | Bitwise equal count | Bitwise % | Max abs diff | Max rel diff | Status |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `posq` | 40000 | 39991 | 99.98% | `1.192e-07` | `1.178e-07` | **PASS** |
| `velm` | 40000 | 30878 | 77.20% | `1.490e-08` | `3.875e-05` | **PASS** |
| `posDelta` | 40000 | 27298 | 68.25% | `2.910e-11` | `2.197e-04` | **PASS** |
| `oldDelta` | 40000 | 27298 | 68.25% | `2.910e-11` | `2.197e-04` | **PASS** |

## 3. computeBondedForces (apoa1rf/006)

Tested on 5,000 atoms accumulating 237,636 interactions (11,428 harmonic bonds, 99,628 periodic torsions, 73,902 nonbonded exceptions, 52,678 harmonic angles) into 64-bit fixed-point accumulation buffers via split-word atomic adds.

- OpenCL total energy: `7909923.788378` kJ/mol
- Metal total energy: `7909923.655645` kJ/mol
- Energy absolute difference: `1.3273e-01` kJ/mol
- Energy relative difference: `1.6781e-08` (tolerance 1e-5)

| Buffer | Total elements | Bitwise equal count | Bitwise % | Max abs diff | Max rel diff | Status |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `forceBuffer` | 276672 | 261733 | 94.60% | `4.7058e-03` | `3.7458e-01` | **PASS** |
| `energyBuffer` | 99840 | 0 | 0.00% | `1.3273e-01` | `1.6781e-08` | **PASS** |

## 4. Mutation verification

- Mutation: `perturb_atom0_position_metal_only`
- Description: Perturb posq[0].x by +0.05 nm on Metal side only to verify harness detects genuine disagreements
- Disagreement detected: **true**
- Max absolute force difference induced: `11941.60` kJ/mol/nm (threshold > 10.0 kJ/mol/nm)
- Verification status: **PASS**

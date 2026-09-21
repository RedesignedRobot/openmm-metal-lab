# OpenMM Common Compute Metal Kernel Census

## Totals

- Total kernel source files: 67
- Compiled with zero errors: 49 (73.1%)
- Failed compilation: 18 (26.9%)

## Root-Cause Categories

| Category | Files Blocked | Count | Judgement |
| :--- | :--- | :--- | :--- |
| `code_snippet_missing_function` | `angleForce.cc`, `bondForce.cc`, `cmapTorsionForce.cc`, `constantPotentialCoulombEnergyForces.cc`, `constantPotentialExceptions.cc`, `constantPotentialExclusions.cc`, `coulombLennardJones.cc`, `customExternalForce.cc`, `customGBChainRule.cc`, `customNonbonded.cc`, `gbsaObc2.cc`, `harmonicAngleForce.cc`, `harmonicBondForce.cc`, `nonbondedExceptions.cc`, `periodicTorsionForce.cc`, `pmeExclusions.cc`, `rbTorsionForce.cc`, `torsionForce.cc` | 18 | Needs kernel source change upstream (encapsulate code fragments into callable `DEVICE` inline functions) |

## Resolved Compatibility Categories

| Category | Mechanism | Resolution |
| :--- | :--- | :--- |
| `kernel_value_parameter_address_space` | MSL prohibits unadorned value parameters in kernel signatures (`invalid type 'thread T' for input declaration`). | Fixed by mechanical rewrite: converts value parameters to `constant T& _in_param` and introduces local mutable variable `T param = _in_param;`. |
| `thread_keyword_collision` | MSL reserves `thread` as an address-space qualifier keyword. Kernels use `thread` as variable names. | Fixed in prelude: `#define thread _mm_thread` after standard library import. |
| `program_scope_thread_indexing` | MSL passes thread coordinates via attributes rather than OpenCL global functions. | Fixed in prelude: declared program-scope global builtins (`[[thread_position_in_grid]]` etc.) mapped to `GLOBAL_ID`, `LOCAL_ID`, `GROUP_ID`, `GLOBAL_SIZE`, `LOCAL_SIZE`, `NUM_GROUPS`. |
| `64bit_atomic_absence` | Apple Silicon GPUs do not provide native 64-bit integer atomics. | Fixed in prelude: implemented 64-bit split-word atomic add with carry propagation on `atomic_uint` pairs. |
| `warp_shuffle_and_intrinsics` | CUDA-style warp shuffle operations (`__shfl`, `__shfl_down`, `__shfl_xor`) and `__ffs`. | Fixed in prelude: mapped to Metal standard library `simd_shuffle`, `simd_shuffle_down`, `simd_shuffle_xor`, and `ctz`. |
| `missing_standard_math` | MSL standard library lacks `erf`, `erfc`, and 4D vector `cross(float4, float4)`. | Fixed in prelude: implemented Abramowitz and Stegun Chebyshev polynomial approximations for erf/erfc and added 4D vector cross overload. |
| `host_interpolated_placeholders` | Kernels contain string substitution points (`PARAMETER_ARGUMENTS`, `COMPUTE_FORCE`, `EXTRA_ARGS`). | Fixed by host string replacement matching upstream platform host drivers (`platforms/common/src/*.cpp`). |

## Detailed Per-File Results

| File | Status | Notes |
| :--- | :--- | :--- |
| `andersenThermostat.cc` | **COMPILED** | Compiled with zero errors |
| `angleForce.cc` | **FAILED** | code_snippet_missing_function |
| `atmforce.cc` | **COMPILED** | Compiled with zero errors |
| `bondForce.cc` | **FAILED** | code_snippet_missing_function |
| `brownian.cc` | **COMPILED** | Compiled with zero errors |
| `cmapTorsionForce.cc` | **FAILED** | code_snippet_missing_function |
| `constantPotential.cc` | **COMPILED** | Compiled with zero errors |
| `constantPotentialCGSolver.cc` | **COMPILED** | Compiled with zero errors |
| `constantPotentialCoulombEnergyForces.cc` | **FAILED** | code_snippet_missing_function |
| `constantPotentialExceptions.cc` | **FAILED** | code_snippet_missing_function |
| `constantPotentialExclusions.cc` | **FAILED** | code_snippet_missing_function |
| `constantPotentialMatrixSolver.cc` | **COMPILED** | Compiled with zero errors |
| `constantPotentialSolver.cc` | **COMPILED** | Compiled with zero errors |
| `constraints.cc` | **COMPILED** | Compiled with zero errors |
| `copyCoordinateBuffers.cc` | **COMPILED** | Compiled with zero errors |
| `coulombLennardJones.cc` | **FAILED** | code_snippet_missing_function |
| `customCVForce.cc` | **COMPILED** | Compiled with zero errors |
| `customCentroidBond.cc` | **COMPILED** | Compiled with zero errors |
| `customCppForce.cc` | **COMPILED** | Compiled with zero errors |
| `customExternalForce.cc` | **FAILED** | code_snippet_missing_function |
| `customGBChainRule.cc` | **FAILED** | code_snippet_missing_function |
| `customGBEnergyN2.cc` | **COMPILED** | Compiled with zero errors |
| `customGBEnergyN2_cpu.cc` | **COMPILED** | Compiled with zero errors |
| `customGBEnergyPerParticle.cc` | **COMPILED** | Compiled with zero errors |
| `customGBGradientChainRule.cc` | **COMPILED** | Compiled with zero errors |
| `customGBValueN2.cc` | **COMPILED** | Compiled with zero errors |
| `customGBValueN2_cpu.cc` | **COMPILED** | Compiled with zero errors |
| `customGBValuePerParticle.cc` | **COMPILED** | Compiled with zero errors |
| `customHbondForce.cc` | **COMPILED** | Compiled with zero errors |
| `customIntegrator.cc` | **COMPILED** | Compiled with zero errors |
| `customIntegratorPerDof.cc` | **COMPILED** | Compiled with zero errors |
| `customManyParticle.cc` | **COMPILED** | Compiled with zero errors |
| `customNonbonded.cc` | **FAILED** | code_snippet_missing_function |
| `customNonbondedComputedValues.cc` | **COMPILED** | Compiled with zero errors |
| `customNonbondedGroups.cc` | **COMPILED** | Compiled with zero errors |
| `dpd.cc` | **COMPILED** | Compiled with zero errors |
| `ewald.cc` | **COMPILED** | Compiled with zero errors |
| `gayBerne.cc` | **COMPILED** | Compiled with zero errors |
| `gbsaObc.cc` | **COMPILED** | Compiled with zero errors |
| `gbsaObc2.cc` | **FAILED** | code_snippet_missing_function |
| `gbsaObcReductions.cc` | **COMPILED** | Compiled with zero errors |
| `gbsaObc_cpu.cc` | **COMPILED** | Compiled with zero errors |
| `harmonicAngleForce.cc` | **FAILED** | code_snippet_missing_function |
| `harmonicBondForce.cc` | **FAILED** | code_snippet_missing_function |
| `integrationUtilities.cc` | **COMPILED** | Compiled with zero errors |
| `langevinMiddle.cc` | **COMPILED** | Compiled with zero errors |
| `lcpo.cc` | **COMPILED** | Compiled with zero errors |
| `minimize.cc` | **COMPILED** | Compiled with zero errors |
| `monteCarloBarostat.cc` | **COMPILED** | Compiled with zero errors |
| `nonbondedExceptions.cc` | **FAILED** | code_snippet_missing_function |
| `nonbondedParameters.cc` | **COMPILED** | Compiled with zero errors |
| `noseHooverChain.cc` | **COMPILED** | Compiled with zero errors |
| `noseHooverIntegrator.cc` | **COMPILED** | Compiled with zero errors |
| `orientationRestraintForce.cc` | **COMPILED** | Compiled with zero errors |
| `periodicTorsionForce.cc` | **FAILED** | code_snippet_missing_function |
| `pme.cc` | **COMPILED** | Compiled with zero errors |
| `pmeExclusions.cc` | **FAILED** | code_snippet_missing_function |
| `pointFunctions.cc` | **COMPILED** | Compiled with zero errors |
| `pythonForce.cc` | **COMPILED** | Compiled with zero errors |
| `qtb.cc` | **COMPILED** | Compiled with zero errors |
| `rbTorsionForce.cc` | **FAILED** | code_snippet_missing_function |
| `removeCM.cc` | **COMPILED** | Compiled with zero errors |
| `rg.cc` | **COMPILED** | Compiled with zero errors |
| `rmsd.cc` | **COMPILED** | Compiled with zero errors |
| `torsionForce.cc` | **FAILED** | code_snippet_missing_function |
| `utilities.cc` | **COMPILED** | Compiled with zero errors |
| `verlet.cc` | **COMPILED** | Compiled with zero errors |

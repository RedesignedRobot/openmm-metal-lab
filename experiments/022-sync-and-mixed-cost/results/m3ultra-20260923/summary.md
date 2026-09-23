### Per-step census on the M3 Ultra (OPENMM_METAL_PROFILE=1; ns/day and wall us/step (off) from the profiling-off run on the host wall clock, fahwu.py time.perf_counter; wall us/step (census) and waits on mach_absolute_time; GPU busy and gaps from command buffers' GPUStartTime/GPUEndTime)

| WU | precision | ns/day (off) | wall us/step (off) | wall us/step (census) | commits | dispatches | finish() | finish wait us | top finish: cause:array n/wait | event waits | event wait us | top event: n/wait | CCMA iter/call | GPU busy us | busy fraction | gaps | gap us |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| dhfr | single | 126.5 | 1366 | 1357 | 4.34 | 51 | 2.34 | 909 | download:ccmaConverged 2.30/902us; download:energySum 0.01/4us; download:kineticEnergy 0.01/3us | 1.01 | 401 | after findBlocksWithInteractions 1.01/401us | 9.1 | 733 | 0.540 | 4.34 | 624 |
| dhfr | mixed | 99.8 | 1730 | 1775 | 4.36 | 51 | 2.37 | 1304 | download:ccmaConverged 2.32/1295us; download:energySum 0.01/4us; download:kineticEnergy 0.01/4us | 1.01 | 415 | after findBlocksWithInteractions 1.01/415us | 9.2 | 1149 | 0.647 | 4.36 | 627 |
| nav | single | 44.9 | 3846 | 3845 | 2.39 | 32 | 0.25 | 311 | download:energySum 0.09/242us; download:kineticEnergy 0.09/51us; download:posq 0.03/18us | 1.09 | 3436 | after findBlocksWithInteractions 1.09/3436us | - | 3736 | 0.972 | 2.39 | 109 |
| nav | mixed | 36.4 | 4745 | 4736 | 2.41 | 32 | 0.30 | 403 | download:energySum 0.09/275us; download:kineticEnergy 0.09/102us; download:posq 0.06/21us | 1.09 | 4213 | after findBlocksWithInteractions 1.09/4213us | - | 4601 | 0.972 | 2.41 | 134 |
| dhfr-implicit | single | 619.0 | 279 | 278 | 2.04 | 17 | 0.04 | 6 | download:kineticEnergy 0.01/2us; download:energySum 0.01/2us; download:posq 0.00/1us | 1.01 | 251 | after findBlocksWithInteractions 1.01/251us | - | 263 | 0.947 | 2.04 | 15 |
| dhfr-implicit | mixed | 468.5 | 369 | 369 | 2.04 | 17 | 0.05 | 7 | download:kineticEnergy 0.01/3us; download:energySum 0.01/2us; download:posq 0.01/1us | 1.01 | 336 | after findBlocksWithInteractions 1.01/336us | - | 356 | 0.963 | 2.04 | 14 |

### Census overhead on the M3 Ultra (host wall us/step, fahwu.py time.perf_counter)

| WU | precision | off | census | change |
|---|---|---|---|---|
| dhfr | single | 1366 | 1357 | -0.6% |
| dhfr | mixed | 1730 | 1776 | +2.6% |
| nav | single | 3846 | 3844 | -0.0% |
| nav | mixed | 4745 | 4736 | -0.2% |
| dhfr-implicit | single | 279 | 278 | -0.4% |
| dhfr-implicit | mixed | 369 | 369 | +0.1% |

#### Gap sites, dhfr single on the M3 Ultra (command buffers' GPUStartTime/GPUEndTime)

| after | before | per step | us/step |
|---|---|---|---|
| updateCCMAAtomPositionsKernel | computeCCMAPositionConstraintForceKernel | 1.27 | 324.0 |
| updateCCMAAtomPositionsKernel | integrateVerletPart2 | 1.00 | 280.7 |
| updateCCMAAtomPositionsKernel | computeCCMAVelocityConstraintForceKernel | 0.02 | 5.1 |
| integrateVerletPart2 | calcCenterOfMassMomentum | 0.00 | 3.4 |
| reduceEnergy | timeShiftVelocities | 0.01 | 2.9 |
| computeKineticEnergy | calcCenterOfMassMomentum | 0.01 | 2.7 |

#### Gap sites, dhfr mixed on the M3 Ultra (command buffers' GPUStartTime/GPUEndTime)

| after | before | per step | us/step |
|---|---|---|---|
| updateCCMAAtomPositionsKernel | computeCCMAPositionConstraintForceKernel | 1.29 | 329.8 |
| updateCCMAAtomPositionsKernel | integrateVerletPart2 | 1.00 | 275.9 |
| updateCCMAAtomPositionsKernel | computeCCMAVelocityConstraintForceKernel | 0.02 | 5.8 |
| integrateVerletPart2 | calcCenterOfMassMomentum | 0.00 | 4.0 |
| reduceEnergy | timeShiftVelocities | 0.01 | 2.9 |
| computeKineticEnergy | calcCenterOfMassMomentum | 0.01 | 2.9 |

#### Gap sites, nav single on the M3 Ultra (command buffers' GPUStartTime/GPUEndTime)

| after | before | per step | us/step |
|---|---|---|---|
| reduceEnergy | computeKineticEnergy | 0.09 | 25.2 |
| (none) | copyFloatBuffer | 0.02 | 22.7 |
| integrateLangevinMiddlePart3 | calcCenterOfMassMomentum | 0.00 | 20.2 |
| computeKineticEnergy | clearThreeBuffers | 0.04 | 16.5 |
| computeKineticEnergy | (none) | 0.02 | 13.0 |
| computeKineticEnergy | scalePositions | 0.02 | 6.8 |

#### Gap sites, nav mixed on the M3 Ultra (command buffers' GPUStartTime/GPUEndTime)

| after | before | per step | us/step |
|---|---|---|---|
| (none) | copyFloatBuffer | 0.02 | 33.3 |
| reduceEnergy | computeKineticEnergy | 0.09 | 26.0 |
| integrateLangevinMiddlePart3 | calcCenterOfMassMomentum | 0.00 | 23.4 |
| computeKineticEnergy | clearThreeBuffers | 0.04 | 17.3 |
| computeKineticEnergy | (none) | 0.02 | 13.0 |
| copyFloatBuffer | scalePositions | 0.02 | 9.6 |

#### Gap sites, dhfr-implicit single on the M3 Ultra (command buffers' GPUStartTime/GPUEndTime)

| after | before | per step | us/step |
|---|---|---|---|
| computeNonbonded | integrateVerletPart1 | 1.00 | 5.4 |
| findBlocksWithInteractions | computeBornSum | 1.01 | 3.2 |
| reduceEnergy | timeShiftVelocities | 0.01 | 2.5 |
| computeKineticEnergy | calcCenterOfMassMomentum | 0.01 | 2.4 |
| integrateVerletPart2 | calcCenterOfMassMomentum | 0.00 | 1.1 |
| computeNonbonded | reduceEnergy | 0.01 | 0.0 |

#### Gap sites, dhfr-implicit mixed on the M3 Ultra (command buffers' GPUStartTime/GPUEndTime)

| after | before | per step | us/step |
|---|---|---|---|
| computeNonbonded | integrateVerletPart1 | 1.00 | 6.3 |
| computeKineticEnergy | calcCenterOfMassMomentum | 0.01 | 2.6 |
| reduceEnergy | timeShiftVelocities | 0.01 | 2.5 |
| integrateVerletPart2 | calcCenterOfMassMomentum | 0.00 | 1.2 |
| findBlocksWithInteractions | computeBornSum | 1.01 | 0.9 |
| computeNonbonded | reduceEnergy | 0.01 | 0.0 |

### Kernel GPU time per step, dhfr on the M3 Ultra (OPENMM_METAL_PROFILE=kernels, one buffer per dispatch, GPUEndTime - GPUStartTime of each buffer)

| kernel | single us | mixed us | mixed - single | share of gap |
|---|---|---|---|---|
| computeCCMAPositionConstraintForceKernel | 57.4 | 185.5 | +128.1 | 30% |
| updateCCMAAtomPositionsKernel | 71.1 | 170.1 | +99.0 | 23% |
| multiplyByCCMAConstraintMatrixKernel | 139.9 | 200.6 | +60.7 | 14% |
| applySettleToPositions | 10.5 | 67.0 | +56.5 | 13% |
| computeNonbonded | 110.6 | 148.2 | +37.6 | 9% |
| integrateVerletPart1 | 7.0 | 19.5 | +12.5 | 3% |
| computeCCMAConstraintDirectionsKernel | 5.5 | 16.8 | +11.4 | 3% |
| integrateVerletPart2 | 7.0 | 18.0 | +10.9 | 3% |
| removeCenterOfMassMomentum | 9.2 | 15.2 | +6.0 | 1% |
| calcCenterOfMassMomentum | 6.2 | 9.7 | +3.5 | 1% |
| computeCCMAVelocityConstraintForceKernel | 0.7 | 2.5 | +1.9 | 0% |
| clearThreeBuffers | 8.7 | 10.2 | +1.5 | 0% |
| computeKineticEnergy | 0.4 | 1.3 | +0.9 | 0% |
| findBlockBounds | 13.1 | 13.8 | +0.7 | 0% |
| applySettleToVelocities | 0.1 | 0.6 | +0.5 | 0% |
| (all kernels) | 853.9 | 1281.9 | +428.0 | 100% |

### Kernel GPU time per step, nav on the M3 Ultra (OPENMM_METAL_PROFILE=kernels, one buffer per dispatch, GPUEndTime - GPUStartTime of each buffer)

| kernel | single us | mixed us | mixed - single | share of gap |
|---|---|---|---|---|
| computeNonbonded | 1190.1 | 1657.4 | +467.3 | 53% |
| applySettleToPositions | 13.3 | 80.7 | +67.4 | 8% |
| applySettleToVelocities | 21.2 | 72.5 | +51.3 | 6% |
| computeKineticEnergy | 28.8 | 80.0 | +51.2 | 6% |
| applyShakeToPositions | 10.0 | 59.3 | +49.3 | 6% |
| applyShakeToVelocities | 9.6 | 58.2 | +48.6 | 6% |
| integrateLangevinMiddlePart2 | 17.8 | 58.9 | +41.1 | 5% |
| integrateLangevinMiddlePart3 | 17.0 | 50.6 | +33.6 | 4% |
| integrateLangevinMiddlePart1 | 13.7 | 40.7 | +27.0 | 3% |
| removeCenterOfMassMomentum | 15.2 | 30.7 | +15.4 | 2% |
| calcCenterOfMassMomentum | 9.3 | 16.9 | +7.6 | 1% |
| sortBuckets | 88.4 | 93.5 | +5.1 | 1% |
| assignElementsToBuckets | 86.9 | 91.7 | +4.8 | 1% |
| findBlocksWithInteractions | 418.8 | 422.9 | +4.1 | 0% |
| computeSortKeys | 15.5 | 19.3 | +3.8 | 0% |
| (all kernels) | 4152.4 | 5035.1 | +882.7 | 100% |

### Kernel GPU time per step, dhfr-implicit on the M3 Ultra (OPENMM_METAL_PROFILE=kernels, one buffer per dispatch, GPUEndTime - GPUStartTime of each buffer)

| kernel | single us | mixed us | mixed - single | share of gap |
|---|---|---|---|---|
| applyShakeToPositions | 7.1 | 50.3 | +43.1 | 46% |
| computeNonbonded | 71.8 | 83.1 | +11.3 | 12% |
| integrateVerletPart1 | 5.9 | 17.1 | +11.1 | 12% |
| integrateVerletPart2 | 5.8 | 15.3 | +9.6 | 10% |
| computeGBSAForce1 | 51.1 | 56.1 | +5.0 | 5% |
| removeCenterOfMassMomentum | 6.1 | 10.1 | +4.0 | 4% |
| calcCenterOfMassMomentum | 5.5 | 8.9 | +3.4 | 4% |
| reduceBornForce | 7.0 | 9.5 | +2.5 | 3% |
| (none) | 9.9 | 11.3 | +1.3 | 1% |
| computeBondedForces | 27.6 | 28.7 | +1.1 | 1% |
| clearFourBuffers | 6.4 | 6.9 | +0.5 | 1% |
| applyShakeToVelocities | 0.1 | 0.5 | +0.4 | 0% |
| computeKineticEnergy | 0.1 | 0.3 | +0.2 | 0% |
| reduceBornSum | 5.6 | 5.8 | +0.1 | 0% |
| timeShiftVelocities | 0.1 | 0.2 | +0.1 | 0% |
| (all kernels) | 298.8 | 392.0 | +93.2 | 100% |

### State after 1000 steps on the M3 Ultra (energy requested every 100), SHA-256 prefixes

| WU | precision | variant | rep | positions | velocities | forces | energies (10 x PE, KE) | final PE kJ/mol | positions, velocities, forces = base rep 1 |
|---|---|---|---|---|---|---|---|---|---|
| dhfr | mixed | base | 1 | 6badb664 | 7a794024 | 82f3229a | c908fd9d | -338476.243266 | yes |
| dhfr | mixed | base | 2 | 6badb664 | 7a794024 | 82f3229a | 95f3ac97 | -338476.243266 | yes |
| dhfr | mixed | p2 | 1 | 6badb664 | 7a794024 | 82f3229a | 77e593c0 | -338476.243266 | yes |
| dhfr | mixed | p2 | 2 | 6badb664 | 7a794024 | 82f3229a | 21845aa2 | -338476.243266 | yes |
| dhfr | mixed | p2p3 | 1 | 6badb664 | 7a794024 | 82f3229a | a02a9610 | -338476.243266 | yes |
| dhfr | mixed | p2p3 | 2 | 6badb664 | 7a794024 | 82f3229a | e776195e | -338476.243266 | yes |
| dhfr | mixed | p3 | 1 | 6badb664 | 7a794024 | 82f3229a | 640731e8 | -338476.243266 | yes |
| dhfr | mixed | p3 | 2 | 6badb664 | 7a794024 | 82f3229a | 48ee9879 | -338476.243266 | yes |
| dhfr | single | base | 1 | c65b930d | 26eabd30 | 609e9905 | 35c0c12b | -338354.809792 | yes |
| dhfr | single | base | 2 | c65b930d | 26eabd30 | 609e9905 | 78204bf6 | -338354.782449 | yes |
| dhfr | single | p2 | 1 | c65b930d | 26eabd30 | 609e9905 | 8404eb43 | -338354.796121 | yes |
| dhfr | single | p2 | 2 | c65b930d | 26eabd30 | 609e9905 | 6f4fcb2b | -338354.790261 | yes |
| dhfr | single | p2p3 | 1 | c65b930d | 26eabd30 | 609e9905 | 56eefb4d | -338354.772683 | yes |
| dhfr | single | p2p3 | 2 | c65b930d | 26eabd30 | 609e9905 | 01688e1f | -338354.792214 | yes |
| dhfr | single | p3 | 1 | c65b930d | 26eabd30 | 609e9905 | 12dc4a25 | -338354.766824 | yes |
| dhfr | single | p3 | 2 | c65b930d | 26eabd30 | 609e9905 | b69b188a | -338354.774636 | yes |
| nav | mixed | base | 1 | df7076a2 | 38b0dae5 | 7b683893 | 7a7312c4 | -1732647.574114 | yes |
| nav | mixed | base | 2 | df7076a2 | 38b0dae5 | 7b683893 | 3c8d40cd | -1732647.574114 | yes |
| nav | mixed | p2 | 1 | df7076a2 | 38b0dae5 | 7b683893 | 7851f309 | -1732647.574114 | yes |
| nav | mixed | p2 | 2 | df7076a2 | 38b0dae5 | 7b683893 | c57d918d | -1732647.574114 | yes |
| nav | mixed | p2p3 | 1 | df7076a2 | 38b0dae5 | 7b683893 | 35e52ea6 | -1732647.574114 | yes |
| nav | mixed | p2p3 | 2 | df7076a2 | 38b0dae5 | 7b683893 | 15c639c2 | -1732647.574114 | yes |
| nav | mixed | p3 | 1 | df7076a2 | 38b0dae5 | 7b683893 | c3837d83 | -1732647.574114 | yes |
| nav | mixed | p3 | 2 | df7076a2 | 38b0dae5 | 7b683893 | 0897fd2a | -1732647.574114 | yes |
| nav | single | base | 1 | c207419f | 9ab42cf1 | f4d3918d | c3e86579 | -1730395.635506 | yes |
| nav | single | base | 2 | c207419f | 9ab42cf1 | f4d3918d | a1a511d7 | -1730395.666756 | yes |
| nav | single | p2 | 1 | c207419f | 9ab42cf1 | f4d3918d | c172856f | -1730395.713631 | yes |
| nav | single | p2 | 2 | c207419f | 9ab42cf1 | f4d3918d | ab4e81f8 | -1730395.682381 | yes |
| nav | single | p2p3 | 1 | c207419f | 9ab42cf1 | f4d3918d | 6d2a15f7 | -1730395.690193 | yes |
| nav | single | p2p3 | 2 | c207419f | 9ab42cf1 | f4d3918d | 69e013c7 | -1730395.729256 | yes |
| nav | single | p3 | 1 | c207419f | 9ab42cf1 | f4d3918d | 690b73db | -1730395.643318 | yes |
| nav | single | p3 | 2 | c207419f | 9ab42cf1 | f4d3918d | a0be8f0f | -1730395.674568 | yes |

### Start-state potential energy, 50 evaluations per context on the M3 Ultra (kJ/mol)

| WU | precision | variant | contexts | distinct values per context | value per context | spread over all variants and contexts |
|---|---|---|---|---|---|---|
| dhfr | mixed | base | 2 | 1 1 | -337088.937137 -337088.937137 | 1.16e-09 |
| dhfr | mixed | p2 | 2 | 1 1 | -337088.937137 -337088.937137 | 1.16e-09 |
| dhfr | mixed | p2p3 | 2 | 1 1 | -337088.937137 -337088.937137 | 1.16e-09 |
| dhfr | mixed | p3 | 2 | 1 1 | -337088.937137 -337088.937137 | 1.16e-09 |
| dhfr | single | base | 2 | 1 1 | -337088.956277 -337088.938699 | 0.0352 |
| dhfr | single | p2 | 2 | 1 1 | -337088.938699 -337088.948464 | 0.0352 |
| dhfr | single | p2p3 | 2 | 1 1 | -337088.928933 -337088.946511 | 0.0352 |
| dhfr | single | p3 | 2 | 1 1 | -337088.940652 -337088.921121 | 0.0352 |
| nav | mixed | base | 2 | 1 1 | -1720827.033847 -1720827.033847 | 6.52e-09 |
| nav | mixed | p2 | 1 | 1 | -1720827.033847 | 6.52e-09 |
| nav | mixed | p2p3 | 1 | 1 | -1720827.033847 | 6.52e-09 |
| nav | mixed | p3 | 1 | 1 | -1720827.033847 | 6.52e-09 |
| nav | single | base | 2 | 1 1 | -1720827.080818 -1720827.033943 | 0.109 |
| nav | single | p2 | 2 | 1 1 | -1720827.049568 -1720827.057381 | 0.109 |
| nav | single | p2p3 | 2 | 1 1 | -1720827.026131 -1720827.080818 | 0.109 |
| nav | single | p3 | 2 | 1 1 | -1720826.971443 -1720827.041756 | 0.109 |

### End-to-end speed, ns/day on the M3 Ultra (host wall clock: fahwu.py time.perf_counter over whole steps, 60 s after 200 warm-up steps, 3 interleaved rounds)

| WU | precision | platform | variant | ns/day per round | median | range | / base | / OpenCL single |
|---|---|---|---|---|---|---|---|---|
| dhfr | single | Metal | base | 130.5 128.7 128.6 | 128.7 | 1.9 | 1.000 | 1.339 |
| dhfr | single | Metal | p2 | 144.9 147.6 147.1 | 147.1 | 2.7 | 1.143 | 1.530 |
| dhfr | single | Metal | p2p3 | 142.9 148.0 151.0 | 148.0 | 8.1 | 1.150 | 1.540 |
| dhfr | single | Metal | p3 | 124.6 124.9 128.8 | 124.9 | 4.2 | 0.970 | 1.299 |
| dhfr | single | OpenCL | shared | 92.8 96.1 98.2 | 96.1 | 5.4 | - | 1.000 |
| dhfr | mixed | Metal | base | 99.9 98.6 97.1 | 98.6 | 2.8 | 1.000 | 1.026 |
| dhfr | mixed | Metal | p2 | 118.3 118.8 118.5 | 118.5 | 0.5 | 1.202 | 1.233 |
| dhfr | mixed | Metal | p2p3 | 120.6 122.8 121.2 | 121.2 | 2.2 | 1.229 | 1.261 |
| dhfr | mixed | Metal | p3 | 97.2 96.7 98.2 | 97.2 | 1.6 | 0.986 | 1.012 |
| nav | single | Metal | base | 44.8 44.9 45.2 | 44.9 | 0.4 | 1.000 | 1.005 |
| nav | single | Metal | p2 | 45.2 45.2 45.2 | 45.2 | 0.0 | 1.006 | 1.011 |
| nav | single | Metal | p2p3 | 45.2 45.1 45.2 | 45.2 | 0.1 | 1.006 | 1.012 |
| nav | single | Metal | p3 | 45.3 45.2 45.0 | 45.2 | 0.3 | 1.006 | 1.011 |
| nav | single | OpenCL | shared | 44.8 44.4 44.7 | 44.7 | 0.4 | - | 1.000 |
| nav | mixed | Metal | base | 36.4 36.5 36.5 | 36.5 | 0.1 | 1.000 | 0.817 |
| nav | mixed | Metal | p2 | 36.4 36.3 36.4 | 36.4 | 0.1 | 0.997 | 0.815 |
| nav | mixed | Metal | p2p3 | 40.3 40.1 40.2 | 40.2 | 0.2 | 1.101 | 0.900 |
| nav | mixed | Metal | p3 | 40.4 40.3 40.1 | 40.3 | 0.3 | 1.103 | 0.901 |
| dhfr-implicit | single | Metal | base | 603.6 600.2 618.0 | 603.6 | 17.7 | 1.000 | 1.029 |
| dhfr-implicit | single | Metal | p2 | 604.1 604.5 604.0 | 604.1 | 0.5 | 1.001 | 1.030 |
| dhfr-implicit | single | Metal | p2p3 | 610.1 599.6 613.3 | 610.1 | 13.7 | 1.011 | 1.040 |
| dhfr-implicit | single | Metal | p3 | 597.6 597.7 618.5 | 597.7 | 20.9 | 0.990 | 1.019 |
| dhfr-implicit | single | OpenCL | shared | 587.0 475.7 586.4 | 586.4 | 111.4 | - | 1.000 |
| dhfr-implicit | mixed | Metal | base | 459.9 462.5 461.2 | 461.2 | 2.5 | 1.000 | 0.787 |
| dhfr-implicit | mixed | Metal | p2 | 451.8 455.9 464.5 | 455.9 | 12.7 | 0.989 | 0.777 |
| dhfr-implicit | mixed | Metal | p2p3 | 473.1 459.2 478.4 | 473.1 | 19.2 | 1.026 | 0.807 |
| dhfr-implicit | mixed | Metal | p3 | 468.9 471.9 473.0 | 471.9 | 4.1 | 1.023 | 0.805 |

### CCMA A/B, ns/day on the M3 Ultra (host wall clock as above; dhfr-hbonds = heavy-atom constraints as bonds, 3 interleaved rounds)

| WU | precision | platform | variant | ns/day per round | median | range | / base | / OpenCL single |
|---|---|---|---|---|---|---|---|---|
| dhfr | single | Metal | base | 128.4 124.0 131.8 | 128.4 | 7.8 | 1.000 | 1.291 |
| dhfr | single | Metal | p2 | 158.2 154.4 147.8 | 154.4 | 10.4 | 1.202 | 1.551 |
| dhfr | single | OpenCL | shared | 97.2 99.5 100.5 | 99.5 | 3.3 | - | 1.000 |
| dhfr-hbonds | single | Metal | base | 220.7 219.6 221.6 | 220.7 | 1.9 | 1.000 | 1.025 |
| dhfr-hbonds | single | Metal | p2 | 220.6 220.5 219.9 | 220.5 | 0.7 | 0.999 | 1.024 |
| dhfr-hbonds | single | OpenCL | shared | 182.2 215.3 215.9 | 215.3 | 33.7 | - | 1.000 |

### Census per variant on the M3 Ultra (OPENMM_METAL_PROFILE=1, 30 s; wall us/step and waits on mach_absolute_time, GPU busy and gaps from GPUStartTime/GPUEndTime)

| variant | WU | precision | wall us/step (census) | commits | finish() | finish wait us | event waits | event wait us | CCMA iter/call (dispatched) | GPU busy us | busy fraction | gap us |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| base-prof | dhfr | mixed | 1775 | 4.36 | 2.37 | 1304 | 1.01 | 415 | 9.2 | 1149 | 0.647 | 627 |
| p2-prof | dhfr | mixed | 1440 | 5.10 | 0.05 | 9 | 3.06 | 1362 | 12.1 | 1177 | 0.817 | 264 |
| base-prof | dhfr | single | 1357 | 4.34 | 2.34 | 909 | 1.01 | 401 | 9.1 | 733 | 0.540 | 624 |
| p2-prof | dhfr | single | 1197 | 5.71 | 0.04 | 7 | 3.66 | 1115 | 14.5 | 780 | 0.652 | 416 |
| base-prof | nav | mixed | 4736 | 2.41 | 0.30 | 403 | 1.09 | 4213 | - | 4601 | 0.972 | 134 |
| p2-prof | nav | mixed | 4743 | 2.41 | 0.30 | 404 | 1.09 | 4207 | - | 4603 | 0.971 | 139 |
| base-prof | nav | single | 3845 | 2.39 | 0.25 | 311 | 1.09 | 3436 | - | 3736 | 0.972 | 109 |
| p2-prof | nav | single | 3828 | 2.39 | 0.25 | 310 | 1.09 | 3425 | - | 3717 | 0.971 | 111 |

### Energy guard: kernel GPU us/step on the M3 Ultra (OPENMM_METAL_PROFILE=kernels, GPUEndTime - GPUStartTime of each buffer), base-prof vs p3-prof

| WU | precision | computeNonbonded base | computeNonbonded p3 | all kernels base | all kernels p3 |
|---|---|---|---|---|---|
| dhfr | mixed | 148.2 | 111.2 | 1281.9 | 1240.7 |
| dhfr | single | 110.6 | 110.8 | 853.9 | 851.9 |
| nav | mixed | 1657.4 | 1223.1 | 5035.1 | 4575.6 |
| nav | single | 1190.1 | 1189.3 | 4152.4 | 4140.0 |

### p3 alone on dhfr single: ns/day on the M3 Ultra (host wall clock as above, 30 s runs, 3 interleaved rounds; the -prof variants have the census on)

| WU | precision | platform | variant | ns/day per round | median | range | / base | / OpenCL single |
|---|---|---|---|---|---|---|---|---|
| dhfr | single | Metal | base | 123.9 121.0 120.9 | 121.0 | 3.0 | 1.000 | - |
| dhfr | single | Metal | base-prof | 121.9 124.7 121.9 | 121.9 | 2.8 | 1.007 | - |
| dhfr | single | Metal | p3 | 121.9 126.4 121.4 | 121.9 | 5.1 | 1.007 | - |
| dhfr | single | Metal | p3-prof | 124.0 122.2 121.7 | 122.2 | 2.3 | 1.010 | - |

### p3 alone on dhfr single: census per round on the M3 Ultra (clocks as in the census per variant)

| variant | WU | precision | wall us/step (census) | commits | finish() | finish wait us | event waits | event wait us | CCMA iter/call (dispatched) | GPU busy us | busy fraction | gap us |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| base-prof | dhfr | single | 1418 | 4.34 | 2.34 | 940 | 1.01 | 429 | 9.1 | 743 | 0.524 | 675 |
| base-prof | dhfr | single | 1386 | 4.34 | 2.34 | 934 | 1.01 | 404 | 9.1 | 742 | 0.536 | 644 |
| base-prof | dhfr | single | 1418 | 4.34 | 2.34 | 956 | 1.01 | 413 | 9.1 | 747 | 0.527 | 671 |
| p3-prof | dhfr | single | 1394 | 4.34 | 2.34 | 930 | 1.01 | 414 | 9.1 | 748 | 0.537 | 646 |
| p3-prof | dhfr | single | 1414 | 4.34 | 2.34 | 951 | 1.01 | 415 | 9.1 | 748 | 0.529 | 666 |
| p3-prof | dhfr | single | 1420 | 4.34 | 2.34 | 957 | 1.01 | 414 | 9.1 | 747 | 0.526 | 673 |


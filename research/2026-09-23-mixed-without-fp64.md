# Mixed precision without fp64 on Apple GPUs

Ranked options. Gains come from the M3 Ultra kernel census in experiments/022 (GPU µs/step) and are estimates, not timings.

1. Energy guard (commit 5f30ddc82). nav nonbonded mixed excess drops from 467 to 34 µs/step, so the nav penalty goes from 23% to about 12%, and dhfr from 27% to about 24%. Risk: none, since trajectories are bitwise identical. Wall timing is pending.
2. CCMA in delta form with float inner math (integrationUtilities.cc:602-762, IntegrationUtilities.cpp:386-391). Keep posDelta df64, compute the per-step residual offset in df64, run everything else in float. Gain on dhfr is 100-200 of its 296 µs CCMA excess, a penalty of about 13-18%. Risk: low. The matrix is already float-grade, truncated at 0.1.
3. SHAKE and SETTLE with float iteration on df64-formed differences, with corrections accumulated in float and added to posDelta once (integrationUtilities.cc:99-558). Gain on nav is 120-160 of 210 µs, and dhfr-implicit about 8% of wall. Risk: low for SHAKE and velocity SETTLE, medium for position SETTLE. Gate that on water-box drift.
4. Pair (hi, lo) storage for the GPU-private df64 arrays (posDelta, oldDelta, CCMA arrays). Gain 1-3%, more if option 2 is skipped. No numeric risk. Engineering risk is moderate: posDelta is copyTo'd from IEEE velm (IntegrationUtilities.cpp:952, 992).
5. Kinetic energy kernel in float per-atom terms plus a multi-group df64 reduction (integrationUtilities.cc:1141). Saves 52 µs on energy steps only. About zero for FAH.
6. Cheaper df64 ops. FMA two-prod already exists (df64.metal:46-49). Dropping the isfinite guards is worth at most 1-2%. Sloppy add is unsafe for position differences, so reject it.
7. Float integrator kicks or float dt: reject. That breaks TestMetalMixedPrecision.cpp:240-271 (1e-12) and the documented "integration in double" contract, for 1-2% gain.
8. Q32.32 or int32 fixed-point positions: reject for speed. Mixed positions are already float pairs (integrationUtilities.cc:74-95). The MINT32 gains are measured against FP32 coordinates. Changing it touches 118 posqCorrection sites.
Stack of 1+2+3 (inference): dhfr about 27% to 8-12%, nav about 23% to 7-9%. CUDA mixed paid 4-11% in the OpenMM 7 paper.

Tiers used below: **verified** means I read the source or document and cite it. **Reported** means a source claims it and I did not check the claim. **Inference** is my reasoning. Nothing here was built, run or timed for this report. The kernel and wall numbers come from existing JSON in experiments/022, which I only summarized.

## 1. What OpenMM mixed actually promises

### The documented contract

- Verified. The User Guide says that in mixed, "forces are computed in single precision but integration is done in double precision" (docs-source/usersguide/library/04_platform_specifics.rst:31-33). The Metal section says integration uses "double-single arithmetic ... about 48 bits of precision" (same file, 124-130).
- Verified. The OpenMM 7 paper (Eastman et al. 2017, PLoS Comput Biol 13(7):e1005659) says: "Forces are computed in single precision, but integration and energy accumulation are done in double precision." Forces use 64-bit fixed-point accumulation in every mode.
- Verified. The developer guide says mixed velocities are `double4` and positions are float plus a float "correction" array. Together they give "the full double precision position" (docs-source/developerguide/06_opencl_platform.rst:70-76).
- Verified. The accuracy the docs publish is ubiquitin in OBC with CUDA, Verlet at 0.5 fs, no constraints and no cutoff. Drift was 4.3e-4 (single), 2.3e-5 (mixed) and 1.1e-7 (double) kT/ns/dof (07_testing_validation.rst:106-127). The same page warns that with constraints, "the level of error will depend strongly on the constraint tolerance" (line 136).
- Verified. In OpenMM 7 Table 5 (DHFR, leapfrog Verlet NVE, 2 fs, HBonds plus rigid water, 10 x 1 ns runs), drift was single 1.557±0.003, mixed -0.0047±0.0008 and double -0.0062±0.0002 kJ/mol/ps. The paper calls mixed and double "not significantly different ... numeric precision is no longer the dominant source of error." Inference: that works out to about 4e-5 kT/ns/dof for mixed, taking dof ≈ 48,400.

So the promise that matters for FAH is the DHFR result. With constraints at a normal tolerance, mixed drift cannot be told apart from double. Mixed does not have to be double-exact. It has to keep precision error below the constraint-tolerance error.

### What the code keeps in double (verified, platforms/common)

- posDelta is `double4` in mixed (IntegrationUtilities.cpp:96-99), along with stepSize `double2` and kineticEnergy `double` (:100-101).
- The CCMA arrays ccmaDistance, Delta1, Delta2, ReducedMass and ConstraintMatrixValue all use `sizeof(double)` in mixed (IntegrationUtilities.cpp:386-391).
- velm is `mixed4`. Positions load as `pos1 + (mixed)pos2`, and on store they split into hi = (real)pos and lo = pos - hi (integrationUtilities.cc:74-95).
- Metal energy buffers are double (MetalContext.cpp:407-408). Nonbonded keeps a `mixed energy` accumulator (nonbonded.metal:31).
- Verlet Part2 rebuilds the velocity from the constrained displacement as `velocity = delta*oneOverDt` (verlet.cc). LangevinMiddle Part3 adds `(delta-oldDelta)*invDt` (langevinMiddle.cc). So posDelta carries velocity information, and it has to be as precise as velm.

### Where upstream already uses float inside mixed (verified)

- SETTLE geometry parameters are `float2` (IntegrationUtilities.cpp:202; kernel arg at integrationUtilities.cc:330), and the kernel reads `float rc = 0.5f*params.y` (integrationUtilities.cc:413).
- SHAKE parameters are `float4` (IntegrationUtilities.cpp:285; integrationUtilities.cc:100).
- The center-of-mass momentum is summed in `float4` even when velm is `mixed4` (removeCM.cc:5-11, 46-71).
- Virtual-site weights are double only in double mode (IntegrationUtilities.cpp:528).
- The CCMA inverse matrix drops every element below 0.1 (`ReferenceCCMAAlgorithm ... 0.1`, IntegrationUtilities.cpp:331; the cutoff test is at ReferenceCCMAAlgorithm.cpp:184). CCMA's matrix is an approximate preconditioner, and storing it in double buys nothing.

### What has to stay double-like (inference, from the above plus Lippert 2007)

1. The position sum (posq plus posqCorrection). It already costs almost nothing.
2. velm accumulation, and the scalars that multiply into it (dt, the kick scale).
3. posDelta and oldDelta, because the integrator turns them back into velocity. Lippert et al. (JCP 126:046101, 2007, verified) showed that recomputing v from position differences under constraints cuts precision to Verlet level unless the differences keep full precision. The effect is large in single precision and negligible in double.
4. The one subtraction per constraint per step where two nearly equal large numbers cancel. In SHAKE that is `ld = d² - |r|²`. In CCMA it is `dist2 - rp2`.
5. Energy and kinetic-energy sums.

Everything else is either a small-magnitude correction or a convergence-bounded iteration. Float relative error there lands on a correction, not on the state.

## 2. How other codes get mixed-class accuracy without cheap fp64

| Code | What stays high precision | Drift | Cost | Tier |
|---|---|---|---|---|
| OpenMM mixed (CUDA) | integration, energy sums, velocities, posDelta; forces fixed point | DHFR -0.0047 kJ/mol/ps, about 4e-5 kT/ns/dof | 10.5% (Titan X), 3.8% (K80) over single, Table 4 | verified |
| AMBER SPFP | fixed-point accumulation of forces and energies, "fixed precision" SHAKE and other critical parts | "energy conservation is equivalent to the full double precision code" | not stated on the page | reported (ambermd.org/gpus16; Le Grand, Götz, Walker, CPC 184:374, 2013; full paper not read) |
| GROMACS mixed | only "critical variables" such as the virial; coordinates, velocities and forces are single | constraint drift "around 0.0001 kJ/mol/ps per particle" in single; single SETTLE rounding "causes the drift to become negative" | double is "20 to 100% slower" | verified (GROMACS reference manual, definitions and molecular-dynamics pages) |
| HALMD | double-single for velocity-Verlet updates and force summation; force evaluation single | 3x (LJ) to 7x (WCA) lower than single, same order as native double; 3e-5 over 2e8 steps | about 20% on a GTX 280 | verified (Colberg and Höfling, CPC 182:1120, 2011) |
| MINT32 (AMBER variant) | 32-bit integer coordinates; FP64 SHAKE/SETTLE geometry | DHFR -9.25e-6 vs DPFP -8.74e-6 vs SPFP -4.64e-5 kT/ns/dof | 84-89% of SPFP speed | verified (J Chem Inf Model 2026, 66(8):4645, PMC13078822) |
| ACEMD 3 | uses OpenMM kernels, so it inherits OpenMM mixed | none separate | none separate | reported (Acellera blog) |

Three things from this table affect our options.

- HALMD is the closest analogue to Metal mixed. It has double-single integration and single forces on hardware with no useful fp64, and it pays 20%. It shows df64 integration reaches double-class drift, which is what Metal already does. It gives no reason to put df64 in the constraint solvers. HALMD has no constraints.
- MINT32 keeps SHAKE and SETTLE geometry in FP64. The GROMACS manual blames SETTLE rounding in single precision for systematic drift. Both point the same way: position SETTLE is where float is riskiest. That ranks option 3 below option 2.
- The GROMACS single-precision constraint drift of 1e-4 kJ/mol/ps per particle works out, by my arithmetic (inference), to about 2e-2 kT/ns/dof for a DHFR-sized system. That is single-class, not mixed-class. GROMACS mixed is a weaker target than OpenMM mixed, so we should not copy it.

Conflicts I found:
- MINT32 says velocities are "maintained in FP32" in one passage and describes FP64 force and velocity arithmetic in another. I could not resolve it from the HTML.
- MINT32 says OpenMM uses FP32 coordinates. That is wrong for OpenMM mixed, which carries posqCorrection (developer guide lines 70-76). I trust the OpenMM source.
- philipturner/metal-float64 reports IEEE FP64 emulation on Apple GPUs at roughly 1:32. It is reported and unchecked, and it does not change the ranking, because df64 is already the cheaper path.

## 3. Options, grounded in our numbers

### Where the mixed cost sits today (verified from experiments/022 JSON, M3 Ultra)

Wall time with profiling off, single vs mixed, in µs/step: dhfr 1366 vs 1730 (+27%), nav 3846 vs 4745 (+23%), dhfr-implicit 279 vs 369 (+32%). The GPU is busy 0.54 (single) and 0.65 (mixed) of the time on dhfr, and 0.97 on nav.

The kernel census (p3-prof, energy guard applied, one command buffer per dispatch) puts the mixed excess in these places.
- dhfr (389 µs total):
  - CCMAPositionConstraintForce +129
  - updateCCMAAtomPositions +97
  - multiplyByCCMAConstraintMatrix +61
  - applySettleToPositions +57
  - Verlet Part1 and Part2 +23
  - CCMA totals about 296 µs, 76% of the excess.
- nav (436 µs total):
  - SETTLE positions +66
  - computeKineticEnergy +52
  - SETTLE velocities +51
  - SHAKE velocities +48
  - SHAKE positions +46
  - LangevinMiddle Parts 1-3 +98
  - computeNonbonded +34
  - removeCM and calcCM +23
- Without the guard (base-prof), nav computeNonbonded went from 1190 to 1657 µs (+467, 53% of the gap).
- The constraint kernels run inside the ccmaConverged sync loop: 2.3 downloads per step on dhfr, with finish wait 902 µs single vs 1295 µs mixed. Inference: on this latency-bound system, GPU time cut from CCMA sits on the critical path and shows up in wall time.

015 (M2, verified from its README) adds one more fact. At 23k atoms, the IEEE decode and encode on every device load and store more than doubles the cost of df64 kernels. Verlet costs 87.3 µs with IEEE storage and 39.6 µs with pair storage. LangevinMiddle costs 138.7 vs 69.1 µs. Most of the mixed penalty in small kernels is format conversion and df64 op count, not memory bandwidth.

### Option 1. Energy guard (done, timing pending)

- Verified. The current `metal` branch still accumulates `energy += tempEnergy` without a guard at nonbonded.metal:84, 140, 302 and 351. Only the final store is inside `#ifdef INCLUDE_ENERGY` (:391). Commit 5f30ddc82 wraps the inner adds. The census drop from +467 to +34 µs shows the Metal compiler was not removing the dead df64 chain.
- Verified. bits.jsonl gives identical position, velocity and force SHA digests for base, p2, p3 and p2p3 in mixed (dhfr 6badb66..., nav df7076a2...). The guard does not change trajectories.
- Inference. nav is GPU-bound at 0.97, so wall time should drop by about 430 µs, from 4745 to about 4310 µs/step, which is +12% over single. dhfr gains at most 38 µs, about 24%.
- Adjacent. OpenCL nonbonded.cl:84 has the same unguarded inner add. That is worth an upstream note, but NVIDIA and AMD compilers may already remove it.

### Option 2. CCMA in delta form with float inner math

The code (verified): computeCCMAPositionConstraintForce (integrationUtilities.cc:602-630) builds `rp_ij = posDelta[i]-posDelta[j] + dir`. Here `dir` is the old bond vector, about 0.1 nm, and posDelta is the step displacement, about 1e-3 nm. It then computes `diff = dist2 - rp2`, which cancels two numbers near 0.01 nm², and `delta1 = reducedMass*diff/rrpr`, a df64 divide. multiplyByCCMAConstraintMatrix (:695-710) is a sparse matvec in df64 over the truncated matrix. updateCCMAAtomPositions (:722-746) adds `damping*invMass*delta2*dir` into posDelta. posDelta is confirmed as the `atomPositions` argument (IntegrationUtilities.cpp:736).

Proposed change (inference):
- Split rp2 as |dir|² + 2 dir·e + e·e, where e is the posDelta difference. Then diff = (dist2 - |dir|²) - 2 dir·e - e·e. The first term is computed once per step in df64 inside computeCCMAConstraintDirections (:559) and stored as a float. SHAKE already uses this form (`ld1-2.0f*rrpr-rpsqij`, integrationUtilities.cc:153).
- Every term left in the iteration is 1e-4 nm² or smaller. Float absolute error there is about 1e-11 nm². The tolerance window is about 2·tol·dist2, which is 2e-7 at tol 1e-5 and still 2e-10 at tol 1e-8. The convergence test (`rp2 > lowerTol*dist2 && ...`, :626) becomes `|diff| < 2·tol·dist2` on the same float quantity.
- Form e in df64 (a subtraction of two df64 loads), then round it to float. The absolute error is about 6e-11 nm.
- Store Delta1, Delta2, ReducedMass and ConstraintMatrixValue as float (IntegrationUtilities.cpp:386-391). The matrix already drops everything under 0.1, and its values come from a float-grade approximate inverse.
- updateCCMAAtomPositions keeps posDelta df64 but adds a float product, which is a DW+FP add. JMP 2017 algorithm 4 costs about half of DW+DW.

Expected gain (inference): multiplyByCCMAConstraintMatrix loses all its df64 work, most of +61 µs. The force kernel loses the df64 divide and most df64 multiplies, most of +129. The update kernel keeps one df64 read-modify-write per atom, so maybe half of +97 goes. That totals about 150-200 µs of the 296 µs CCMA excess on dhfr, which puts dhfr at roughly 13-18% over single, before option 3. Because CCMA runs inside the sync loop, I expect most of that to reach wall time. This is unmeasured.

Risk: low. The iteration is still bounded by the same tolerance on the same residual. Float errors sit 3-4 orders of magnitude below the tolerance window at FAH's 1e-5 (all three WUs use constraintTolerance="1e-05", verified in /private/tmp/openmm-metal-bench/fah-wu/*/integrator.xml). One thing to watch is the iteration count. If float noise costs an extra iteration per step, that adds a sync, and at 0.25 ms per sync that wipes out the gain. Measure iterations per step before measuring time.

### Option 3. SHAKE and SETTLE with float iteration on df64 differences

SHAKE (verified, integrationUtilities.cc:99-217). The loop is already in delta form. The df64 costs come from:
- `fabs(ld1-2.0f*rrpr-rpsqij) / (d2*tol)`, a df64 divide on every iteration check (:153),
- the df64 divide in `acor` (:155),
- df64 accumulation into the xpi/xpj copies of posDelta, for up to 15 iterations.

Proposed change (inference):
- Compute rij and `ld = d² - |rij|²` in df64 once, then round both to float.
- Iterate in float on a per-atom float correction that starts at zero.
- At the end, add the correction to df64 posDelta once.
- Replace the division by `d2*tol` with a comparison against a precomputed float threshold.

The correction is about 1e-5 to 1e-4 nm, so float error on it is about 1e-12 nm. That is well below the 1e-7 nm² tolerance scale.

SETTLE positions (verified, :328-487). The work is analytic, with no iteration. It forms relative vectors in df64 from `loadPos` plus posDelta (:344-372), then runs about 3 sqrt, 9 divides and the rotation in df64, while its geometry parameters are already float2.
- Running the rotation in float gives the final bond lengths a relative error of about 6e-8, around 6e-9 nm. That is a hundred times below the 1e-5 error SHAKE and CCMA are allowed in the same system, but it is systematic rounding. GROMACS documents exactly this producing a negative drift in single precision.
- Safer variant: do the float SETTLE, then one df64 SHAKE-style correction on the three distances in delta form. That costs about one SHAKE iteration.

SETTLE and SHAKE velocities (:220-326, :489-558). These solve for velocity corrections that are added to df64 velm. Float error lands on the correction, not on the velocity, so the risk is lower than for positions.

Expected gain (inference): nav's four constraint kernels carry 210 µs of excess, and a 60-75% cut is 125-160 µs. On dhfr, SETTLE positions carries +57 µs, so 30-40 µs. On dhfr-implicit, SHAKE positions carries +43 µs in base-prof. About 30 µs of that is roughly 8% of its 369 µs wall time, if it is on the critical path.

Risk: low for SHAKE and the velocity kernels, medium for position SETTLE. Ship SETTLE positions last and behind the drift gate in section 4.

### Option 4. Pair storage for GPU-private df64 arrays

- Verified. df64.metal:27-29 and :140-150. Device memory holds IEEE binary64. The device and constant constructors decode (df64_from_ieee at :204, with a tie-handling slow path), and operator= encodes (df64_to_ieee at :267, a two_sum, rint and 64-bit integer path).
- 015 recommended IEEE storage so the host needs no conversion hooks. That is correct for velm, posq, energies and anything downloaded.
- posDelta, oldDelta and the CCMA arrays never go to the host. The one exception is `cc.clearBuffer` (CommonKernels.cpp:447).
- The catch (verified): computeKineticEnergy and computeShiftedVelocities use posDelta as scratch for velm through a raw `copyTo` (IntegrationUtilities.cpp:952, 973, 992, 1029). Pair-format posDelta would need a converting copy kernel there, or a separate scratch buffer.
- Gain (inference): about 1-3% of wall time after options 2 and 3, more if they are skipped. The integration kernels' excess (nav LM Parts 1-3 +98, dhfr Verlet +23) is partly decode and encode of posDelta and oldDelta. velm stays IEEE.

### Option 5. Kinetic energy kernel

- Verified. computeKineticEnergy (integrationUtilities.cc:1141) runs as one workgroup of at most 512 threads (IntegrationUtilities.cpp:113-115). It does a df64 divide per atom and a df64 tree reduction in threadgroup memory.
- nav shows +52 µs at 0.09 dispatches per step, so it only costs anything on reporting steps.
- The fix is a float per-atom term (v²·m, computed from df64 velm then rounded, which is fine for a reported scalar), a multi-workgroup kernel and a df64 final sum.
- FAH gain is about zero (inference). Low priority.

### Option 6. Cheaper df64 ops

- Verified. df64_two_prod already uses `fma(a, b, -p)` (df64.metal:46-49). Add is AccurateDWPlusDW (:315-323). Multiply is DWTimesDW3 (:336-343). Each carries an isfinite guard (:317, 327, 338, 347, 355, 367).
- Removing the guards saves a compare and select per op. Estimate (inference): ≤1-2%.
- JMP 2017's sloppy DW+DW add has unbounded relative error when the operands have opposite signs, and our df64 subtractions are exactly position and delta differences. Reject.
- df64 also requires `mathMode .safe` (015 README). This blocks P8 (relaxed math) for any library that includes df64. Options 2 and 3 shrink the df64 surface, which makes a split-library P8 easier later.

### Option 7. Float integrator kicks or float dt. Reject.

TestMetalMixedPrecision.cpp:240-271 asserts positions and velocities to 1e-12 after one Verlet or LangevinMiddle step, and the comment at :216 puts mixed at about 1e-15. A float kick fails this test. It also breaks the documented contract of integration in double. The remaining integrator excess (dhfr Verlet +23 µs, nav LM +98 µs) is better attacked through option 4.

### Option 8. Fixed-point positions (Q32.32 or MINT32 int32). Reject for speed.

- Verified. Metal mixed positions are already a float hi plus float lo pair (integrationUtilities.cc:74-95). Loading one is one df64+float add.
- MINT32's gain is over FP32 coordinates. Its drift is close to DPFP, but OpenMM mixed already sits there (Table 5).
- A switch to fixed point would touch 118 posqCorrection lines in common kernels across 22 files (my grep count from before this summary). It would also change every plugin's position load. No expected speedup. Keep it on the shelf for an accuracy argument, not a performance one.

## 4. Validation protocol

This follows OpenMM's own practice (07_testing_validation.rst) and the DHFR protocol from the paper. The lab adopted it in PROGRAM.md's Accuracy section.

1. Unit tests. Full Metal ctest in Mixed, including TestMetalMixedPrecision (its 1e-12 integration check must stay green). TestVerletIntegrator's constraint checks (tests/TestVerletIntegrator.h:130: energy 0.01, constraints 1e-4 over 1000 steps) must pass unchanged.
2. Constraint residuals. For dhfr and nav, log the distribution of |r² - d²|/d² after every constraint call. Do it at tol 1e-5 (FAH) and at 1e-8. Report iterations per step too, since that is where a float CCMA could lose time.
3. Force table. Rerun the User Guide metric (median of 2|Fref-Ftest|/(|Fref|+|Ftest|) against Reference, 07_testing_validation.rst:70-79). Forces are unchanged by these options, so this is a regression guard.
4. DHFR NVE drift. The OpenMM 7 Table 5 protocol: leapfrog Verlet, 2 fs, HBonds plus rigid water, 10 x 1 ns, energy every 1 ps, linear fit, mean ± SE. Run it for baseline df64 and for each option. Pass means Welch's t-test shows no difference from baseline, and the result is inside 3 SE of the published mixed -0.0047±0.0008 kJ/mol/ps. The lab notes already say 0.1 ns runs measure the protocol, not the platform, so do not shorten it. Cost is about 2.4 h per variant on the M3 Ultra (inference, from dhfr at 1.73 ms/step).
5. Water-box NVE for SETTLE. A rigid-water-only box, as Lippert (901 waters, 1 fs) and MINT32 used. It isolates the position-SETTLE risk GROMACS documents. Option 3's SETTLE-position half ships only if drift here matches baseline.
6. Ubiquitin OBC, 0.5 fs, no constraints. The User Guide figure. It should be unchanged, since no option touches the unconstrained integrator. It is a cheap check that nothing leaked.
7. Units and threshold. Report drift in kT/ns/dof and compare with the 1e-5 mixed threshold in choderalab/openmm-validation. That README marks the project unfinished and says the test "never actually triggered errors", so treat the threshold as a convention, not a spec.
8. Determinism. Ten contexts per variant with the same seed. Positions, velocities and forces SHA digests must match, as bits.jsonl already does.
9. FAH gates. FAHBench-style state tests from the 020 mock core: RMS force difference ≤ 5 kJ/mol/nm, |dPE| and |dKE| ≤ 10 kJ/mol, no NaN, velocity and force caps. Also the checkpoint round-trip.
10. Hardware. Run everything on M2 (mini) and M3 Ultra (Studio). Per-chip ulp tables stay as in 015.

What would convince maintainers is items 4 and 5 side by side with baseline, and item 2 showing the residual distribution is unchanged at tight tolerance. Our evidence has to beat the claim "float constraint math breaks the mixed promise", and the DHFR Table 5 comparison is the test they already trust.

## Caveats

- Every gain is an estimate from GPU kernel time in a profiling mode that uses one command buffer per dispatch, on the M3 Ultra only. dhfr is latency-bound, so GPU savings may not reach wall time one-for-one. Nothing here was timed for this report.
- The energy guard wall time was still being measured when I wrote this. Option 1's numbers are predictions.
- I did not read the FAHBench source (StateTests.cpp returned 404). The tolerances come from the lab's mockcore.py docstring. I also do not know FAH's production constraint tolerance beyond these three WUs.
- AMBER SPFP drift numbers are not on the page I read, and I did not read the full CPC paper.
- MINT32 contradicts itself on FP32 vs FP64 velocities.
- The kT/ns/dof conversions for OpenMM 7 Table 5 and for GROMACS are my arithmetic, with approximate dof counts.
- Option 2's delta-form residual is my design. It mirrors what SHAKE already does, but no upstream CCMA uses it.
- Adjacent. Single-precision energy digests vary run to run in bits.jsonl. That is not investigated here.

## Pointers

- /Users/amir/code/mini/openmm-metal/platforms/common/src/kernels/integrationUtilities.cc:99-762. The whole constraint surface for options 2 and 3, in one file.
- /Users/amir/code/mini/openmm-metal/platforms/common/src/IntegrationUtilities.cpp:96-105, 386-391, 693-776, 946-1029. Buffer types, kernel argument wiring, and the posDelta-as-velm-scratch copies that constrain option 4.
- /Users/amir/code/mini/openmm-metal/platforms/metal/src/kernels/df64.metal:27-375. The storage model and op costs. Read it before estimating any df64 change.
- /Users/amir/code/mini/openmm-metal-lab/experiments/022-sync-and-mixed-cost/results-m3ultra-20260923. The census behind every number here. Rerun summarize.py after the guard timing lands.
- OpenMM 7 paper Table 5 (https://doi.org/10.1371/journal.pcbi.1005659) and Lippert et al. 2007 (https://doi.org/10.1063/1.2431176). These are the drift target and the reason posDelta must stay df64.

Sources:
- https://doi.org/10.1371/journal.pcbi.1005659
- https://doi.org/10.1063/1.2431176
- https://arxiv.org/abs/0912.3824
- https://manual.gromacs.org/current/reference-manual/algorithms/molecular-dynamics.html
- https://manual.gromacs.org/current/reference-manual/definitions.html
- https://ambermd.org/gpus16/
- https://pmc.ncbi.nlm.nih.gov/articles/PMC13078822/
- https://github.com/choderalab/openmm-validation
- https://github.com/philipturner/metal-float64

# Lane: mixed precision (df64 cost)

Worktree /Users/amir/code/mini/ultra-mixed, branch ultra/mixed from 6df2b8bcb. M3 Ultra scratch
/tmp/openmm-metal-bench/ultra-mixed. Started 2026-09-24 19:15Z.

## Starting point

025 on the M3 Ultra (host clock, ns/day, 4 fs LangevinMiddle, HBonds): mixed minus single per step is
138 us (gbsa), 237 us (rf), 224 us (pme), 232 us (dhfr), 270 us (apoa1rf), 275 us (apoa1pme),
696 us (cellulose). The gap is mostly fixed per step, not per atom, so it looks like latency-bound df64
kernels rather than throughput.

How Metal mixed works at 6df2b8bcb: common kernels unchanged, `double` is a macro for the df64 struct
(two floats) in df64.metal. Device memory holds IEEE doubles, so every device load of a mixed value runs
df64_from_ieee and every store runs df64_to_ieee. Same mixed semantics as CUDA: posq float4 plus
posqCorrection float4, velm/posDelta/energy in double, forces in single. So the port does no more df64
than CUDA does; the cost is df64 arithmetic, the IEEE conversions and kernel latency.

Per step on the integration path (benchmark.py): Part1, SETTLE vel, SHAKE vel, Part2, SETTLE pos,
SHAKE pos, Part3, all serial in one encoder. gbsa has no water (SHAKE only).

## Log

- 19:33Z census build (6df2b8bcb plus a lab-only patch, OPENMM_METAL_CENSUS=1 gives each dispatch its
  own command buffer and sums GPUEnd-GPUStart per kernel name) started on the M3 Ultra.
- 19:40Z census of 6df2b8bcb (each dispatch in its own command buffer, GPU us per step, so absolute
  numbers include ~5 us of buffer overhead per kernel; census-base/ on the M3 Ultra). Mixed minus single:
  pme 234 us = SETTLE pos +59, SETTLE vel +42, SHAKE pos +46, SHAKE vel +38, Langevin Part1-3 +37,
  COM calc/remove +8. gbsa 126 us = SHAKE pos +46, vel +39, Part1-3 +36. apoa1pme 283 us, same kernels.
  Forces (nonbonded, PME, bonded, GBSA) cost the same in both precisions. SHAKE takes ~50 us in mixed on
  every system from 2.5k to 92k atoms, so these kernels are bound by one thread's df64 dependency chain.
  (amber20-dhfr also shows the minimizer's single-block reductions, 120 us per call, one-time only.)
- Candidate 1 (constraints): SHAKE pos/vel keep the residual in mixed and compute the correction in real
  (iterative, so the next iteration corrects the float error); SETTLE vel keeps the relative velocities in
  mixed and the geometry and 3x3 solve in real. Single and double compile to the same arithmetic as
  before (real == mixed there). df64 gains += and -= overloads for float.
- Candidate 2 (df64 ops): sloppy df64+df64 add (11 flops instead of 20; absolute error stays ~u^2 of the
  larger operand), mul without the lo*lo term, division via one reciprocal, sqrt via rsqrt.
- 20:25Z c1 committed locally as 007aa8444 (not pushed), synced to ultra-mixed/src, shared build.sh
  running. Drift check written (drift.py, drift.sh in ultra-mixed): benchmark.py's gbsa and amber20-dhfr,
  2 fs, 100 ps, velocities from a fixed seed, total energy every 0.5 ps, least-squares slope. Two
  integrators, because VerletIntegrator only applies position constraints: VerletIntegrator, and
  velocity Verlet as a CustomIntegrator with addConstrainVelocities, which runs SETTLE and SHAKE on
  velocities every step. Seeds 1 and 2 at tolerance 1e-5, seed 1 at 1e-7 to check that the iterative
  refinement still converges when the tolerance is below float resolution.
- 20:31Z census of c1 and c1+c2 (GPU us/step, mixed; single from census-base):

  | kernel | base | c1 | c1+c2 | single |
  |---|---|---|---|---|
  | pme total | 945.0 | 890.9 | 871.9 | 711.0 |
  | SETTLE pos | 69.9 | 68.2 | 51.9 | 10.8 |
  | SHAKE pos | 53.5 | 38.5 | 35.5 | 7.7 |
  | SHAKE vel | 44.8 | 33.0 | 31.9 | 6.4 |
  | SETTLE vel | 50.7 | 27.8 | 26.5 | 8.8 |
  | Part1+2+3 | 57.2 | 57.0 | 55.3 | 21.0 |
  | gbsa total | 443.7 | 430.5 | 421.1 | 318.2 |

  c1 cuts the pme gap from 234 to 180 us, c2 to 161 us. SHAKE is still 4 to 5x single after c1: the
  loop still evaluates the residual in mixed every iteration, and a converged cluster takes several.
- 20:32Z A/B screen queued (screen1: base, c1, c1+c2, all mixed, 7 tests, 2 x 15 s).
- Candidate 3 (SHAKE warm start, mixed only): before the mixed loop, SHAKE runs to convergence in real on the
  change in the displacements (or velocities), which is small, so its residuals are good to about 1e-9 of d^2.
  The mixed loop from c1 then checks the result, which normally takes one pass with nothing to correct, and
  still converges for any tolerance.
- Candidate 4 (SETTLE positions, mixed only): Newton's method on the three bond lengths, with the corrections
  along the old bonds weighted by inverse mass, which is the system SETTLE solves analytically. Iterations run
  in real until the residuals are within 1e-6 of d^2 (typically three), then the corrections are folded into
  the mixed displacements and one last step from residuals in mixed takes them to ~1e-12. The analytic
  version costs about 250 df64 operations plus 5 sqrt and 12 divisions per water; this one about 70.
- New check (constraints.py, checks.sh): 200 benchmark.py steps, then the max and RMS relative error of every
  constraint length from getState's double positions, water and SHAKE separately, at tolerance 1e-5 and 1e-8.
- 20:45Z the lease is now a FIFO queue, 15+ deep, and ab.sh re-queues per (round, test), so screen1 (14
  queue passes) could not finish before the cap. Killed it. Each queued slot now runs one bundle of at most
  20 min, with nested ab.sh/gate.sh: pass 1 = checks + census c3/c4 + drift (base vs the c1-c4 stack, 50 ps,
  both integrators); pass 2 = screen 2 x 15 s, gbsa/pme/apoa1pme, base/c1/c2/c3/c4; pass 3 = confirm 3 x 30 s;
  pass 4 = gate.sh on the stack; pass 5 = reserve.
- Local commits (not pushed): c1 007aa8444, c2 99bdaa69d, c3 b78e0b9d5, c4 552992315, c5 67385a385. Trees
  ultra-mixed (c1), t2..t5 built with the shared build.sh.
- Candidate 5 (LangevinMiddle, all precisions but only changes mixed): the force kick, the noise and the
  constraint velocity correction computed in real, accumulated into mixed velocities.
- 20:54Z t3, t4 and t5 built. The queue moves one slot per lease, so passes 3 to 5 would likely start after
  the cap. Pass 1 now does what decides the commits: the screen first, alone on the GPU (base and c1..c5 in
  mixed, gbsa and pme, 2 x 15 s), a pme census of c1-c4, then the untimed work in parallel, since GPU
  contention doesn't change a correctness result: constraint checks, NVE drift of base and the c1-c5 stack
  (50 ps, both integrators, seed 1 at 1e-5 and 1e-7, seed 2 at 1e-5), gate.sh --quick on the stack, and
  ctest -R 'TestMetal.*Mixed$' on the stack. Pass 2 is the 3 x 30 s confirmation of the stack against base
  (gbsa, pme, apoa1pme), then the Single ctests, which completes ctest -R TestMetal.
- 21:20Z review of c1..c5 (fresh-context reviewer, float32 emulation of the kernels). One real defect: c1's
  SETTLE on velocities is a one-shot solve, so with float directions and a float solve it left a relative
  velocity along the bonds of up to 2.3e-6 nm/ps (old mixed code: 6e-15), whatever the tolerance. Fixed in c1:
  the relative velocities are measured in mixed along the mixed bond vectors, and in mixed a second pass removes
  what the first leaves (emulated worst case 9.5e-13). Two smaller fixes: the float compound operators in df64
  only take float (a long operand went through float before), and the c3 float warm start stops at 1e-7*d2 for
  positions and 1e-5 for velocities, above its rounding error, so tight tolerances don't spend 15 float sweeps
  first (benchmark.py uses 1e-5, so the timings don't change). The rest checked out: the Newton SETTLE matches
  the analytic one to 4e-17 nm in double emulation and reaches 9e-13 of d^2 in float32 emulation.
- Also from the review, for the lead: the common-kernel changes (c1, c3, c4, c5) apply to CUDA, OpenCL and HIP
  mixed too, since they key on USE_MIXED_PRECISION. With the SETTLE fix they keep mixed accuracy there, but
  nobody has timed them on those platforms.
- 21:22Z offline compile check: mkmetal.py assembles the source MetalContext::createModule builds
  (defines, df64, common, intrinsics, vectorOps, rewritten kernel signatures) and `xcrun metal` compiles it
  on the M3 Ultra without the GPU. integrationUtilities and langevinMiddle compile in single and mixed at the
  new stack, with the same warnings as 6df2b8bcb; a planted error fails as it should.
- 21:25Z rebased stack: c1 b86a3649f (90+/57-), c2 1adbfc3b4 (15+/17-), c3 933483458 (108+), c4 cef4b80cf
  (78+), c5 0cad63bc2 (14+/10-). The five trees are rebuilding; pass 1 waits for the chain.
- 21:25Z pass 1 got the lease at 21:24:45Z, just before the rebuild chain started, and waited for it as planned.
  The incremental builds take 8 s each, faster than sync.sh, so t5's build started 4 s before its sync ended:
  its Metal plugin still holds the old c1 and c3 while BUILT names the new commit and src hash, so ab.sh's
  staleness check passed. $M, t2, t3 and t4 hold the new kernels (checked by grepping the plugin for the new
  code). The screen's c5 column is therefore c5 on the old c1 and c3: c5/c4 on gbsa is still clean (no water,
  and the c3 floor doesn't bind at 1e-5), pme is not. census.sh, which pass 1 calls between the screen and the
  untimed work, now rebuilds t5 first, so the checks, drift, forces and ctests use the right stack.
  Rule for next time: sync every tree before starting any build.
- 21:33Z screen A (2 x 15 s, mixed, ns/day medians; builds from other lanes ran during 14 of 24 runs, base pme
  spread 6.9%): base gbsa 829.9, pme 389.3; c1 895.1, 423.7; c1+c2 889.4, 435.7; +c3 909.2, 436.1; +c4 913.8,
  449.5; +c5 929.0, 453.6. Per commit: c1 +7.9% gbsa, +8.8% pme; c2 -0.6%, +2.8%; c3 +2.2%, +0.1%; c4 +0.5%,
  +3.1%; c5 +1.7%, +0.9% (c5's pme number ran on the old c1 and c3). Stack c1-c5 against base: 1.119 gbsa,
  1.165 pme.
- 21:42Z pass 1 correctness, c1-c5 stack (t5) against ultra-base, mixed:
  - forces against Reference (gate.sh --quick): PASS.
  - NVE drift, 50 ps at 2 fs, kT/ns per degree of freedom. dhfr at 1e-5: vv base -9.1e-3, stack -1.0e-2;
    verlet base -7.0e-3, stack -6.6e-3. dhfr at 1e-7: vv base -4.6e-4, stack +3.7e-4; verlet base +4.0e-4,
    stack -2.3e-4. gbsa drifts by +0.09 to +0.17 in both builds at every tolerance (base mean 0.13 over 6 runs,
    stack 0.12 over 5), so its drift comes from the force field setup, not the integrator, and the two builds
    are inside each other's spread. dhfr is the sensitive case and matches base.
  - Constraint lengths after 200 LangevinMiddle steps, max relative error: SHAKE 4.96e-6 against 4.98e-6 at
    1e-5 and 2.26e-8 against 2.25e-8 at 1e-8; SETTLE 2.5e-8 base, 3.1e-8 stack, at both tolerances. Both SETTLE
    numbers sit at float rounding of the constraint lengths, which the kernels get as float.
  - ctest TestMetal*Mixed: 53 of 55 pass. FlexibleBarostatMixed is stochastic. TestMetalMixedPrecisionMixed fails
    at line 228: one step of LangevinMiddle on free particles must match double to 1e-12. c5 computes the force
    kick in float (force and dt/2^32 rounded to float), an error of about 1e-7 of the kick, 5e-10 nm/ps here.
    CUDA's mixed precision computes that kick in double, so c5 breaks what mixed precision promises. Dropped
    (kept on branch ultra/mixed-c5-dropped, not pushed).
- RULES.md now says a common-code change must be gated to Metal. c1, c3 and c4 changed platforms/common for every
  platform. New commit 6c97bd5de on top of c4 compiles them only when USE_METAL and USE_MIXED_PRECISION are both
  defined (EMULATED_MIXED_PRECISION, one macro at the top of integrationUtilities.cc) and puts the original code
  back in the #else branches. Checked on the M3 Ultra with clang -E: the preprocessed kernel is identical to
  6df2b8bcb for no defines, mixed, double, Metal, Metal double and HIP mixed, and identical to c4 for Metal mixed
  except the SETTLE velocity loop count, now the literal 2. So Metal single runs base code and the Metal mixed
  timings of t4 hold for the tip. It compiles offline in single and mixed. Stack diff against 6df2b8bcb: 320+/17-.
- 21:50Z queue: pass 2 = TestMetalMixedPrecisionMixed on t4, then confirm base against c1-c4 (3 x 30 s, gbsa, rf,
  pme), then screen c1..c4 on rf (2 x 15 s). Pass 3 = correctness of 6c97bd5de in t5: constraints and drift at
  1e-8 against base with seeds 1 and 2, forces, TestMetal*Mixed. The M2 gets the same drift and constraint checks
  (ultra-m2/mixed against ultra-m2/base, one process at a time in the M2's mkdir lease). Passes 4 and 5 were
  dropped to stay near the GPU budget.
- 21:53Z full gate (gate.sh, no --quick) queued on t5 = 6c97bd5de, logs in ultra-mixed/t5/gate-20260924T215313Z.
- 21:54Z M2 constraint checks at 1e-8 (ultra-m2/mixed = 6c97bd5de against ultra-m2/base, 200 LangevinMiddle steps):
  SHAKE max relative length error 2.26e-8 base, 2.32e-8 gated on pme; 2.26e-8 and 2.30e-8 on gbsa. SETTLE 2.51e-8
  base, 3.08e-8 gated, the same numbers as on the M3 Ultra. The 3.08e-8 is exactly the float rounding of TIP3P's
  H-H length (0.15139006545 stored as the float 0.15139006078, -3.085e-8): SETTLE gets its lengths as float2 on
  every platform, and the Newton solve lands on the stored length. The analytic solve's extra float roundings
  happen to land nearer the double length here. Not a solver accuracy loss.
- 22:00Z M2 NVE drift at 1e-8, 50 ps at 2 fs, kT/ns per degree of freedom, base against 6c97bd5de. dhfr: vv seed 1
  +4.9e-4 / +2.7e-4, verlet seed 1 -5.5e-4 / -7.0e-4, vv seed 2 -1.7e-3 / -6.2e-4. gbsa: vv seed 1 0.126 / 0.102,
  verlet seed 1 0.198 / 0.115, vv seed 2 0.202 / 0.160. No worse than base. (A first launcher I thought had
  failed on quoting did run, so the checks ran twice; the repeated rows match to every digit, and I stopped the
  second copy at 22:04Z.)
- 22:02Z TestMetalMixedPrecisionMixed passes on t4 (c1-c4), which confirms c5 as the cause of its failure.
- 22:08Z confirmB, 3 rounds of 30 s, mixed, ultra-base against t4 (c1-c4, the same kernels g1 compiles on Metal
  mixed). Median ns/day base / stack: gbsa 838.5 / 923.9 (1.102, rounds 1.090 to 1.106), rf 492.1 / 566.3 (1.151,
  rounds 1.151 to 1.232), pme 402.3 / 445.4 (1.107, rounds 1.107 to 1.113). One-minute load was 5.6 to 26.9 during
  the runs, so another lane shared the machine; rf base spread 15%, the others under 2%.
- 22:11Z screenRF, 2 x 15 s, mixed rf, each commit against the one before: c1 1.061, c2 1.044, c3 1.004, c4
  1.045; c4 stack against base 1.162 (spreads 0.5 to 2.1%, load 4 to 5, one run with a build running).
- Keep rule per commit, with screen A (gbsa, pme) and screenRF (rf): c1 +7.9 / +8.8 / +6.1% keeps; c2 -0.6 /
  +2.8 / +4.4% keeps on rf; c4 +0.5 / +3.1 / +4.5% keeps on rf; c3 +2.2 / +0.1 / +0.4% gains 3% nowhere, so the
  SHAKE warm start goes, and its 104 lines with it. All of c2 and c4's gains sit under 5%, so the bundle is
  the claim, not the commits.
- 22:14Z new candidate g2: branch ultra/mixed-g2 = c1 b86a3649f, c2 1adbfc3b4, c4 3dfd569d7 (cherry-pick, clean),
  gate 5cc0ba5af (g1's file minus the two warm-start loops, same message). 216+/17- against 6df2b8bcb, against
  320+/17- for g1. clang -E: base == g2 for all six non-Metal-mixed configurations; for Metal mixed, g2 matches
  c1+c2+c4 except the SETTLE velocity loop bound, as g1 did. Built at t4 on the M3 Ultra (plugin has no warm
  start, 11 EMULATED_MIXED_PRECISION strings) and on the M2 (9 s of build steps with ccache).
- 22:15Z M2: m2-correct-g2.sh runs only g2 (same cases and seeds; base rows from the 22:00Z run), one launch,
  one process tree checked with ps. Waits behind ultra-pme's M2 lease.
- 22:17Z the queue is 28 deep and drains about one hold per 6 min, so no full gate that re-queues per ctest part
  can finish before the freeze through the queue alone. Killed my queued g1 full gate (still waiting for its first hold) and
  queued gate.sh (full) on t4 = g2 at 22:17:22Z, log logs/gate-full-g2.out. Pass 4 (pass-d, head of the queue,
  after pass 3) runs the g2 screen (base vs g2, gbsa/pme/rf, 2 x 15 s), then checks4, drift4 (g2 only, pass 3's
  seeds), gate.sh --quick and the Metal mixed ctests on t4.
- 22:21Z pass 3, g1 6c97bd5de (t5) against ultra-base on the M3 Ultra, all at 1e-8, 50 ps at 2 fs, kT/ns/dof:
  | integrator | test | seed | base | g1 |
  |---|---|---|---|---|
  | verlet | dhfr | 1 | -1.7e-4 | +5.2e-4 |
  | verlet | dhfr | 2 | -5.0e-4 | -1.4e-4 |
  | vv | dhfr | 1 | +7.3e-4 | +9.6e-4 |
  | vv | dhfr | 2 | -4.8e-4 | -5.8e-4 |
  | verlet | gbsa | 1 | +0.143 | +0.125 |
  | verlet | gbsa | 2 | +0.134 | +0.135 |
  | vv | gbsa | 1 | +0.142 | +0.147 |
  | vv | gbsa | 2 | +0.147 | +0.178 |
  dhfr drift changes sign from seed to seed in both builds and stays under 1e-3, which is the noise of a
  50 ps fit (the energy's rms is 5 to 7 kJ/mol against a 3 kJ/mol total drift). gbsa drifts +0.1 to +0.2 in
  every build on both chips. Constraints: SHAKE max 2.26e-8 base, 2.33e-8 g1 (pme) and 2.25e-8 base, 2.57e-8
  g1 (gbsa); SETTLE 2.51e-8 base, 3.08e-8 g1. Forces against Reference: PASS. ctest TestMetal*Mixed: 55 of 55
  (the rerun step then reran two stale entries from pass 1's LastTestsFailed.log, both passed; ctest keeps
  that file after a clean run, so pass 4 reruns only when the first run reports failures).
- 22:19Z M2, g2 5cc0ba5af (same cases and seeds, base rows from 22:00Z): dhfr vv s1 +1.4e-5 (base +4.9e-4),
  verlet s1 +1.05e-3 (base -5.5e-4), vv s2 +1.1e-4 (base -1.7e-3); gbsa vv s1 0.123 (0.126), verlet s1 0.127
  (0.198), vv s2 0.117 (0.202). Constraints: SHAKE 2.26e-8 on pme and gbsa, the same as base, where g1 gave
  2.32e-8 and 2.30e-8 (2.33e-8 and 2.57e-8 on the M3 Ultra); SETTLE 3.08e-8. So the warm start also cost a
  little SHAKE accuracy at 1e-8, and without it SHAKE matches base. I haven't checked why.
- 22:25Z screenG2, 2 x 15 s, mixed, ultra-base against g2 5cc0ba5af (t4), alone on the GPU, load 3 to 4, no
  build overlap. Median ns/day: gbsa 837.7 / 918.4 (1.096, rounds 1.094 to 1.099), rf 482.1 / 566.0 (1.174,
  rounds 1.152 to 1.196), pme 401.9 / 448.8 (1.117, rounds 1.116 to 1.117). confirmB's c1-c4 stack with the
  warm start gave 1.102, 1.151 and 1.107, so dropping c3 costs at most about 0.6% on gbsa, inside the noise.
- 22:35Z pass 4 correctness, g2 5cc0ba5af (t4) on the M3 Ultra, 1e-8, 50 ps, kT/ns/dof, base from pass 3:
  dhfr verlet s1 -7.8e-4 (base -1.7e-4), s2 -2.6e-4 (-5.0e-4), vv s1 -5e-6 (+7.3e-4), s2 +5.9e-4 (-4.8e-4);
  gbsa verlet 0.149 / 0.133 (0.143 / 0.134), vv 0.122 / 0.076 (0.142 / 0.147). Constraints: SHAKE max 2.26e-8
  pme and 2.25e-8 gbsa, the same as base; 5.0e-6 at 1e-5, the same as base; SETTLE 3.08e-8. Forces against
  Reference: PASS. ctest TestMetal*Mixed: 55 of 55.
- Incident: pass 4's guard looked for " 0 tests failed", but this ctest prints "100% tests passed out of 55"
  with no failure count when nothing fails, so it ran ctest --rerun-failed. t4 had no LastTestsFailed.log,
  and with no log --rerun-failed runs the whole suite (446 tests, one at a time). It ran for 3 min 51 s inside
  my own hold, then I killed it; one orphaned TestOpenCLCustomIntegrator ran about 35 s into ultra-plugins'
  correctness hold before I killed it too. Reported to the lead.
- 22:36Z pushed to mini: ultra/mixed = 5cc0ba5af (c1 b86a3649f 90+/57-, c2 1adbfc3b4 15+/17-, c4 3dfd569d7 78+,
  gate 5cc0ba5af 104+/14-; 216+/17- in total). Local only: ultra/mixed-g1 (6c97bd5de, with the warm start) and
  ultra/mixed-c5-dropped. Messaged the lead. Mixed ratios against ultra-base (screenG2): gbsa 1.096, rf 1.174,
  pme 1.117. Full gate on t4 queued at 22:17:22Z.
- Learnings:
  - ctest --rerun-failed is not "rerun if anything failed". After a clean run it reruns the last failures if an
    older LastTestsFailed.log survives (ctest doesn't delete it), and runs every test if there is none. Rerun
    by name from the failed list in the first run's output, or not at all.
  - A float increment applied once breaks mixed precision's contract (TestMetalMixedPrecision wants one step
    to match double to 1e-12). Moving work to real only works where a mixed check follows and iterates.
  - Per-commit screens pay off: the bundle looked like one win, but the warm start (108 lines) gained nothing
    measurable and cost SHAKE accuracy at 1e-8.
  - Sync every tree before starting any build (21:25Z). Launch remote waiters from a script file, not nested
    quotes, and check ps once: a launch that printed nothing did run, and the checks ran twice (22:04Z).
- Where the rest of the gap is (census of c4, GPU us/step, mixed minus single). pme: 132 us left of 234 =
  SHAKE pos +26 and vel +25, SETTLE pos +20 and vel +18, Langevin Part1-3 +35, COM calc and remove +8. gbsa:
  98 us left of 126 = SHAKE +25 and +25, Part1-3 +32, COM +7. c3's census confirms the screen: SHAKE pos
  35.5 to 33.2 us, the rest flat. Levers I didn't get to, for whoever picks this up:
  - SHAKE still costs 31 to 33 us per call on every system size, so one thread's dependency chain sets it. A
    mixed residual needs posDelta and the old positions, which the kernels read as IEEE double and convert to
    df64. Storing mixed as a float pair (the "float plus correction" lever) would remove those conversions,
    but posDelta and velm are shared with host code that expects double, so it touches the whole platform.
  - Langevin Part1-3 (+35 us): c5 showed the kick must stay in double. Part1 and Part3 bracket the constraint
    kernels, so fusing them needs the constraints inside the same dispatch, which only works where every
    cluster fits in one threadgroup.
- 22:37Z M3 Ultra cleanup: removed cen, cen2, cen4, cand and their prefixes and venvs, t2, t3, t5, the c1 build
  at the lane root (src, build, prefix, venv, BUILT), metalcheck, pp and the sync tarballs; kept t4 (the full
  gate runs on it), logs, screens, censuses and jsonl data. t4's venv still imports. M2: kept the g2 build in
  ultra-m2/mixed for further M2 checks; its sync artifacts are gone.
- 22:38Z the g2 full gate's first ticket is 27th of 36 in the queue, waiting since 22:17Z.

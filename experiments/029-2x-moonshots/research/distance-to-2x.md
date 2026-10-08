# Distance to 2x, per test

2026-09-27 15:55Z. Build ultra-r1 (8ae6cf17b), before any round 2 landing. No GPU time was used for this page; it combines night wall numbers with the M0 kernel census. Generator: `lanes/results/m0/distance.py` (prints the table).

## Verdict

Single, closest first: rf is already past 2x. apoa1ljpme needs 5.3% off the step, pme 6.5%, dhfr 9.6%. Then cellulose 14.7%, apoa1pme 15.3%, apoa1rf and stmv 18.7%, gbsa 30.0%.

Mixed (against OpenCL single), closest first: rf 9.6%, apoa1ljpme 13.7%, pme 19.3%, cellulose 22.4%, dhfr 22.9%, apoa1pme 24.2%, stmv 25.6%, apoa1rf 31.1%, gbsa 45.7%.

The earlier read ("pme, dhfr and cellulose within about 10% in single, gbsa furthest") holds for pme, dhfr and gbsa. Cellulose is at 14.7%, not 10%, and sits with apoa1pme. apoa1ljpme was missing from the read and is the closest of all at 5.3%.

No test is launch-bound. GPU busy is 0.84 to 0.96 of the wall step. gbsa is the most launch-heavy: about 36 us of its 217 us step is idle, 2.4 us per dispatch.

## Table

Wall step in us per step = 345600 / (ns/day), host clock, benchmark.py. OpenCL is Window 2 single (dedicated night window, 3x30 s). Metal r1 = int028 Window 2 x the paired 3x30 s r1/int028 ratio from the MAX_BITS confirmation (`lanes/results/nonbonded/report.md`, pre-repair table; r1 keeps MAX_BITS 0 for single PME, so its † rows apply to r1). The paired A/B cancels day load to first order; no window has run on r1 yet (step 5 will).

"2x" is half the OpenCL step. "Gap" is Metal minus 2x, with the share of the Metal step to cut. "GPU sum" is the census kernel time per MD step and "Busy" is GPU sum over the wall step. Each family is GPU us per step, and the parenthesis is the share of that family that would have to go to close the whole gap alone. Over 100% means that family can't close it by itself. "other" is wall minus GPU sum.

| Test | Prec | OpenCL us | Metal us | 2x us | Gap us (cut) | GPU sum | Busy | Families, us (share of the gap each would need to cut alone) |
|---|---|---:|---:|---:|---|---:|---:|---|
| gbsa | single | 304.1 | 217.2 | 152.1 | 65 (30.0%) | 182 | 0.84 | GB 78 (84%), nonbonded 42 (154%), bonded 27 (243%), integration 19 (345%), list 13 (494%), other 36 (183%) |
| gbsa | mixed | 304.1 | 279.9 | 152.1 | 128 (45.7%) | 241 | 0.86 | GB 85 (150%), integration 73 (176%), nonbonded 42 (303%), bonded 28 (457%), list 13 (974%), other 39 (328%) |
| rf | single | 532.6 | 240.2 | 266.3 | met | 226 | 0.94 | nonbonded 100, list 51, bonded 51, integration 23, other 14 |
| rf | mixed | 532.6 | 294.5 | 266.3 | 28 (9.6%) | 277 | 0.94 | nonbonded 100 (28%), integration 71 (40%), list 55 (52%), bonded 49 (58%), other 18 (158%) |
| pme | single | 663.4 | 354.8 | 331.7 | 23 (6.5%) | 320 | 0.90 | PME 107 (22%), nonbonded 92 (25%), list 50 (46%), bonded 44 (52%), integration 25 (94%), other 35 (67%) |
| pme | mixed | 663.4 | 411.1 | 331.7 | 79 (19.3%) | 363 | 0.88 | PME 106 (75%), nonbonded 91 (87%), integration 70 (114%), list 49 (161%), bonded 44 (179%), other 48 (165%) |
| dhfr | single | 614.9 | 339.9 | 307.5 | 32 (9.6%) | 315 | 0.93 | PME 105 (31%), nonbonded 93 (35%), bonded 48 (67%), list 40 (81%), integration 25 (128%), other 25 (129%) |
| dhfr | mixed | 614.9 | 398.8 | 307.5 | 91 (22.9%) | 360 | 0.90 | PME 105 (87%), nonbonded 94 (97%), integration 70 (130%), bonded 46 (197%), list 42 (220%), other 38 (238%) |
| apoa1rf | single | 1231.7 | 757.8 | 615.8 | 142 (18.7%) | 662 | 0.87 | nonbonded 384 (37%), list 176 (81%), bonded 73 (194%), integration 27 (522%), other 96 (149%) |
| apoa1rf | mixed | 1231.7 | 893.2 | 615.8 | 277 (31.1%) | 752 | 0.84 | nonbonded 389 (71%), list 181 (153%), integration 105 (264%), bonded 74 (375%), other 141 (197%) |
| apoa1pme | single | 1909.4 | 1127.2 | 954.7 | 173 (15.3%) | 979 | 0.87 | nonbonded 362 (48%), PME 311 (56%), list 168 (103%), bonded 106 (163%), integration 29 (585%), other 148 (117%) |
| apoa1pme | mixed | 1909.4 | 1258.7 | 954.7 | 304 (24.2%) | 1063 | 0.84 | nonbonded 366 (83%), PME 312 (97%), list 168 (181%), integration 108 (282%), bonded 106 (287%), other 196 (155%) |
| apoa1ljpme | single | 2718.7 | 1435.1 | 1359.3 | 76 (5.3%) | 1224 | 0.85 | PME 455 (17%), nonbonded 442 (17%), list 186 (41%), bonded 105 (72%), integration 30 (252%), other 211 (36%) |
| apoa1ljpme | mixed | 2718.7 | 1574.6 | 1359.3 | 215 (13.7%) | 1319 | 0.84 | PME 461 (47%), nonbonded 451 (48%), list 187 (115%), integration 109 (197%), bonded 106 (203%), other 255 (84%) |
| cellulose | single | 7192.5 | 4216.8 | 3596.3 | 621 (14.7%) | 4037 | 0.96 | nonbonded 1755 (35%), PME 1152 (54%), list 663 (94%), bonded 378 (164%), integration 82 (758%), other 180 (346%) |
| cellulose | mixed | 7192.5 | 4634.1 | 3596.3 | 1038 (22.4%) | 4327 | 0.93 | nonbonded 1762 (59%), PME 1087 (95%), list 661 (157%), integration 430 (242%), bonded 377 (275%), other 307 (338%) |
| stmv | single | 18590.6 | 11428.3 | 9295.3 | 2133 (18.7%) | 9822 | 0.86 | nonbonded 4741 (45%), PME 2378 (90%), list 1685 (127%), bonded 752 (284%), integration 213 (1004%), other 1607 (133%) |
| stmv | mixed | 18590.6 | 12486.0 | 9295.3 | 3191 (25.6%) | | | no census; use the single families plus the mixed integration tax |

## What closes each gap

One family alone closes the gap at a cut of 50% or less in these rows:

- apoa1ljpme single: PME or nonbonded at 17%, list at 41%. round3-plan puts bet 2 (spread) alone at 74-133 us against this 76 us gap.
- pme single: PME 22%, nonbonded 25%, list 46%. At 23 us this is the smallest gap in us.
- dhfr single: PME 31%, nonbonded 35%. round3-plan puts bets 2 and 3 together at 25-37 us against this 32 us gap.
- cellulose single: nonbonded 35%. PME needs 54%. This is bet 1 territory, or bets 2 and 3 together.
- apoa1rf single: nonbonded 37%. There's no PME here, so it's bet 1 or nothing.
- apoa1pme single: nonbonded 48%. Only bet 1 at full strength, or several bets stacked.
- stmv single: nonbonded 45%. Same as apoa1pme.
- rf mixed: nonbonded 28%, integration 40%. Bet 5 (mixed integration) alone does it.
- apoa1ljpme mixed: PME 47%, nonbonded 48%. Needs two bets.
- gbsa single: nothing closes it alone. GB needs 84%. GB plus the 36 us of launch gaps is 114 us against a 65 us gap, so bet 4 (one-pass GB) has to remove both kernel time and dispatches.

Every other mixed row needs a combination. The mixed integration tax (mixed minus single integration) is 45-54 us on the small tests, 78-79 us on apoa1 and 348 us on cellulose. That tax is 171% of the rf mixed gap, 57% of pme's, 49% of dhfr's and 34% of cellulose's, so bet 5 is the first lever for mixed on the small tests.

gbsa mixed needs 128 us. GB, integration and launch gaps add up to 197 us, so it would take 65% of all three. I'd call it out of reach this round, which matches round3-plan.

## Launch-bound or kernel-bound

"other" divided by the sampled dispatches per step is 1.25-2.8 us on gbsa, rf, pme and dhfr. That matches the 1.88 us per dispatch measured in 028 (the Metal 4 comparison), so on these four tests "other" is launch gaps. It's 16% of gbsa single's step, 10% of pme single's and 6% of rf single's.

On apoa1, cellulose and stmv the same ratio is 6-23 us per dispatch. That's too large for launch gaps. It's sampled-out kernel time, so on these tests the family numbers are a floor. Scaling each family by wall / GPU sum (1.04-1.19x) gives an upper bound.

## Caveats

- The xctrace shader timeline drops rows on long steps. distance.py counts only MD steps: spans between integrate rows, with the minimizer and prof.py's between-window force evaluations excluded. When a once-per-step kernel was sampled on under 90% of steps, its mean sampled duration is scaled up to the step count. This applied to gridSpreadCharge on cellulose single (424 of 712), apoa1pme mixed (1931 of 2266), apoa1ljpme mixed (2838 of 3658) and stmv single, plus gridInterpolateForce on stmv. stmv's spread had only 4 sampled calls. Treat its PME figure (2378 us) as rough. 028's split was about 3540 us of spread in an 11405 us step.
- These are r1 numbers. The mixed-e4 landing (b0c76cb7c on ultra/integrated) and the other round 2 wins are not in them. round3-plan's "after r2" columns apply those factors.
- The single-PME MAX_BITS 0 gain is in r1 and in these numbers: pme 1.090, dhfr 1.085, apoa1pme 1.016 over int028. If the gate repair's old single-PME policy ever replaces it, pme single moves from 6.5% to about 14% and dhfr from 9.6% to about 17%.
- Census source: `ultra-r2-mixed/census/<test>-<prec>-intervals.xml` (r1, day, xctrace Metal System Trace). stmv single is `ultra-infra/m0/ocl/amber20-stmv-metal-intervals.xml`. Kernel durations are GPU timestamps and aren't inflated by the profiler's host load. The step wall comes from the night numbers, never from xctrace.

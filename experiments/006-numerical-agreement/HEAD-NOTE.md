# Head's note on 006

Accepted. The same program bodies give the same physics through Metal and through Apple's OpenCL, on the M2 and the M3 Ultra: integrator positions within one unit in the last place, bonded energy within 17 parts per billion, and the mutation turns the comparison red.

Read these with care:

- CORRECTED in experiments/010-compute-nonbonded/HEAD-NOTE.md: the call sites below sit under USE_DOUBLE_PRECISION, single precision never calls erfc, and this paragraph's conclusion is wrong. Original text: The `erfc` finding matters more than the lane says. The head checked the dumps: computeNonbonded calls `erfc(alphaR)` directly, four sites per program, in both the rf and the pme program. At alphaR near 3, the edge of the usual Ewald range, erfc is about 2e-5, so the 005 stand-in's absolute error of 4.8e-7 is a 2% force error there. The degree-7 rational fit (3.8 ppm) or something as good is required before 010.
- The run log prints PASS next to the 100.5% `erfc` row. The tolerance on that row is absolute only. The finding is right, the label is wrong.
- 5.4% of the fixed-point force words differ from OpenCL. The size (0.005 kJ/mol/nm at most) fits different floating point contraction or fast math defaults between the two compilers, and does not fit lost carries, which would show as errors of 2^32 fixed-point units. Unproven. Experiment 007 settles it by switching Metal's fast math off and comparing again.
- The `energyBuffer` row reports 0% bitwise equal with a difference equal to the difference of the totals. That row looks like it compares sums, not elements. The total is what matters; the per-element figure should be ignored.
- The bonded inputs are synthetic and hot: 7.9 million kJ/mol on 5,000 atoms. Good for stressing accumulation, not a physical configuration.
- The first build hung for six minutes inside `waitUntilCompleted` on the M3 Ultra and the head killed it. The lane added timeouts and status checks and did not report the cause. Unknown cause, kept on the list for 008.

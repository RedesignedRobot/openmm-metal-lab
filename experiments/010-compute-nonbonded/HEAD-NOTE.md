# Head's note on 010

Accepted. Agreement is settled; speed splits by chip, and the M2 result is a loss.

- Agreement on real captured ApoA1 buffers: on the M2 the OpenCL kernel reproduces the captured forces bit for bit, the Metal translation does too on apoa1rf and is within 0.11 ppm of the largest force on apoa1pme, and the native variants are within 7.9 ppm. Energies agree to 0.006 ppm. Each native variant has a mutation that turns the gate red.
- Speed, M3 Ultra: native variant C at threadgroup size 32 runs 1.61x (rf) and 1.56x (pme) faster than OpenCL.
- Speed, M2: every Metal version is slower than OpenCL. OpenCL 2.66 ms (rf) and 2.53 ms (pme); translation 3.22 and 3.48; best native 3.24 and 3.03. That is 0.82x. On the chip this lab exists for, and on the kernel peastman's condition names, Metal loses today.

Head's checks:

- Math mode is not the cause. The head reran the M2 benchmark with the translation compiled safe, relaxed and fast: 3.22, 3.51 and 3.51 ms on rf, 3.48, 3.56 and 3.56 on pme. Fast math is slower, not faster. (The patch reached one compile site, the translation's. The native variants printed identical bits in all three runs, so they are compiled elsewhere with their own options; their math mode is unverified.)
- The three native variants land within 1% of each other on the M2 and the threadgroup sweep is flat, while the same changes give 1.6x on the M3 Ultra. So on the M2 the kernel is bound by something none of the variants touch. Candidates, none tested: memory bandwidth (100 GB/s on the M2), the split-word atomic force accumulation, and whatever Apple's OpenCL compiler does that the Metal runtime compiler does not.
- Struck from the lane's report: "OpenCL's driver maintains microarchitectural instruction pairing". No measurement supports it.
- Struck: the erfc candidate table in the run log. It gives the degree-7 fit a maximum absolute error of 2.0e-4, against 4.2e-7 measured in 007 for the same fit. One of the two harnesses evaluates it wrongly.

A correction to the head's own note on 006. It said computeNonbonded calls `erfc(alphaR)` directly and that the prelude's erfc would put a 2% error on forces. The head had grepped the call sites without reading the lines above them: all four sit under `#ifdef USE_DOUBLE_PRECISION`. In single precision OpenMM inlines its own approximation (Abramowitz and Stegun, from Hastings) and never calls erfc. A Metal platform is single precision, so the prelude's erfc does not affect nonbonded forces. The missing erf and erfc in MSL still matter for custom forces that use them in expressions.

Next: 010b, find what binds computeNonbonded on the M2 before moving to PME. This is the maintainer's acceptance condition; it outranks the rest of the programme.

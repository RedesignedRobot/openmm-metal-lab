@philipturner, here are the long-run numbers from the OpenMM 7 paper protocol on my M3 Ultra: DHFR in explicit solvent (23,558 atoms), AMBER99SB-ILDN, TIP3P, rigid water, HBonds, PME at 0.9 nm, `VerletIntegrator` at 2 fs. Each run is 20 ps of Langevin from its own seed, then 1 ns of NVE.

| Platform | Precision | Constraint tol | ewaldErrorTolerance | Runs | Drift (kJ/mol/ps) |
|---|---|---|---|---:|---:|
| Metal | mixed | 1e-8 | 1e-5 | 10 | -0.0005 ± 0.0007 |
| Metal | single | 1e-8 | 1e-5 | 4 | -0.084 ± 0.002 |
| Metal | mixed | 1e-8 | 5e-4 | 10 | +0.062 ± 0.004 |
| CPU | double integration | 1e-8 | 5e-4 | 1 | +0.045 |
| CUDA (paper) | mixed | | | 10 | -0.0047 ± 0.0008 |
| CUDA (paper) | double | | | 10 | -0.0062 ± 0.0002 |

Metal mixed drifts -0.0005 ± 0.0007 kJ/mol/ps over 1 ns. That's zero within error and below the paper's CUDA mixed and double rows, so df64 is holding up exactly as it should. Two settings matter at this level. With benchmark.py's ewaldErrorTolerance of 5e-4, PME error leaves a +0.06 floor that the CPU platform shows too. With the default constraint tolerance of 1e-5, the constraint residual dominates on every platform. So I ran 1e-8 for constraints and 1e-5 for PME.

Your fencing idea works. I compiled everything in relaxed mode with the df64 code fenced by `#pragma METAL fp math_mode(safe)`, and df64 stayed exact. The speedup was only 1.7-2.5%, because today's force kernels are held back by atomics and memory, not arithmetic. Once the nonbonded rewrite makes them compute-bound, I'll bring it back.

@peastman, yes, I wrote the df64 code with AI agents. It's built on Knuth's TwoSum and FMA TwoProd, the same building blocks as Thall's paper, and it passes the checks I described above. I'd love to try yours. I'll run it through the same harness (the 2^20-input error bounds, the 1e-12 LangevinMiddle check against double, and this drift protocol) and keep whichever does better.

Progress since my last update: rf single now runs at 2x OpenCL, and apoa1ljpme, pme and dhfr single are within 10% of it. Mixed picked up another 3-7% on the M2 today. The next round goes after nonbonded and PME charge spreading, which is where the rest of the 2x lives.

I built this in collaboration with Claude Fable 5.1, OpenAI GPT-6 Astra and Claude Opus 5.5.

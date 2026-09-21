# Head's note on 007

Accepted with two claims struck. cdx marked the round failed only because run.sh rewrites matrix.json with fresh timings during the gate; the gate itself exited 0.

Established by execution on both chips:

- MSL has no `erf` or `erfc` in any language version from 1.1 to 4.1. A Metal platform must ship its own. The degree-7 rational fit is as accurate as OpenCL's builtin over 0 to 4 (1.5 ppm against 1.2 ppm).
- Program-scope thread builtins need MSL 3.1, so the approach from 002 and 005 sets macOS 14 as the floor. All 26 programs build under 3.1, 3.2, 4.0 and 4.1.
- Under `mathMode = .safe` with precise functions, sqrt, rsqrt, reciprocal, divide, fma, asin, acos and normalize are bit-identical to OpenCL over a million inputs. With fast math they are not (asin 43% identical, up to 4 units in the last place). A Metal platform that wants OpenCL's numbers compiles with safe math.
- Runtime compile cost is the same as OpenCL: 26 programs cold in 712 ms (M3 Ultra) and 796 ms (M2) against 688 ms for clBuildProgram; warm under 1 ms because the system caches. Start-up time is not an argument for or against Metal.
- No offline Metal compiler exists with the Command Line Tools alone. Runtime compilation from source is the only route that works on a stock machine, which suits OpenMM because it already compiles at context creation. MTLBinaryArchive cannot skip makeLibrary.
- Function constants cut a parameter-change recompile from 60 ms to 39 ms. Too small to justify leaving OpenMM's textual defines.

Struck:

- The erfc GPU cost table. The benchmark kernel evaluates the same input 50 times in a loop; the result is loop invariant, the compiler is free to hoist it, and 50 million calls in 0.8 ms would exceed the M2's memory bandwidth if real. The numbers measure one dispatch. The report's "1.4x to 4.5x faster than OpenCL" also contradicts its own log (0.91x). erfc cost gets measured inside computeNonbonded in 010, where it matters.
- "The remaining 4.9% is reassociation and contraction." Safe math forbids reassociation, and the lane showed no experiment that isolates contraction. What the data supports: safe math moves bonded agreement from 94.6% to 95.1%, every single operation matches, so the residue comes from how the two compilers combine operations. Lost carries stay ruled out by size. Open item: compile the bonded program with contraction off on both sides and see whether it reaches 100%.

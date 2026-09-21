# Experiment 013: does NORPG's Metal branch build and pass OpenMM's tests here

## Question

NORPG/openmm, branch Objective-C, head 8f6a7332, is the only Metal platform in progress for openmm/openmm#5397. Does it build without Xcode on macOS 27, which of OpenMM's own platform tests pass on an M3 Ultra and an M2, and what does each failure come down to?

## Why this one

peastman answered the 2026-09-21 comment and accepted the macOS 14 floor and the missing erfc. The kernel questions are settled. What upstream lacks now is test evidence for the actual platform code, and OpenMM's AI policy welcomes AI for bug finding and tests.

## Method

Build the branch at the pinned commit in a worktree under /Users/mas/code/wt, out of tree, with the Metal platform and the CPU and Reference platforms on. Run the Metal platform's ctest set once per chip with a per-test timeout. Record pass, fail, timeout or crash per test with the first failing assertion. For each failure, find the cause by reading the code and one minimal reproduction, and say "unexplained" when that does not settle it. Nothing in the branch is modified except in a separate patch file per proposed fix.

## Result

The branch builds without full Xcode on macOS 27 using Command Line Tools 27.0 and AppleClang 21.0.
Runtime compilation via Metal avoids any need for the offline Metal compiler.
The build required `-DOPENMM_BUILD_C_AND_FORTRAN_WRAPPERS=OFF` to prevent a configuration failure when Doxygen is missing.

The branch registers one test for the Metal platform in CTest: `TestMetalComputeContext`.
The test passed on both chips:
- Apple M3 Ultra: passed in 0.94 seconds.
- Apple M2: passed in 1.31 seconds.

Zero tests failed, crashed, or timed out.
No patches were required.

The test validates the Common compute runtime interfaces (context, arrays, queues, events, and compilation) against standalone MSL smoke kernels.
The branch does not register an OpenMM simulation platform, so standard OpenMM simulation force tests (`Test*Force`) do not yet run on the Metal platform.

Architectural findings from code inspection:
- The branch compiles MSL at runtime with `MTLLanguageVersion3_0` and `fastMathEnabled = YES`. Upstream program-scope builtins require MSL 3.1 (macOS 14 floor). Safe math (`mathMode = .safe`) is required to achieve bit-level agreement with OpenCL.
- `MetalKernel::execute` encodes onto a new command buffer for every kernel dispatch. As established in Experiment 008, unbatched dispatch incurs high host overhead (15 to 24 microseconds per kernel). Whole-step batching is required to match OpenCL performance.
- `MetalQueue::wait` checks `marker.status < MTLCommandBufferStatusCommitted` and raises an exception on uncommitted buffers, preventing indefinite hangs on uncommitted command buffers.

# Head note on 013

Accepted. I checked the three code claims against the branch at 8f6a7332: `MetalContext.mm:167-168` sets `MTLLanguageVersion3_0` and `fastMathEnabled = YES`, `MetalKernel.mm:74` takes a new command buffer per kernel execute, and `MetalQueue.mm` commits before it waits.

The branch is the Common Compute runtime layer only: six `.mm` files and one test, which passes on both chips. There is no Platform registration yet, so none of OpenMM's force and integrator tests can run. There is nothing to report as a bug.

What the lab's results say about the three choices, for when the author asks: 3.0 must become 3.1 for the program-scope builtins peastman proposed (007); fast math breaks agreement with OpenCL, safe math with precise functions restores it (007, 010); one command buffer per kernel costs 15 to 24 us per dispatch against 0.11 us inside one encoder (008).

Next useful step is on the author's side. The lab waits for the branch to move or for a request.

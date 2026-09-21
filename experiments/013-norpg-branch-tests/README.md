# Experiment 013: does NORPG's Metal branch build and pass OpenMM's tests here

## Question

NORPG/openmm, branch Objective-C, head 8f6a7332, is the only Metal platform in progress for openmm/openmm#5397. Does it build without Xcode on macOS 27, which of OpenMM's own platform tests pass on an M3 Ultra and an M2, and what does each failure come down to?

## Why this one

peastman answered the 2026-09-21 comment and accepted the macOS 14 floor and the missing erfc. The kernel questions are settled. What upstream lacks now is test evidence for the actual platform code, and OpenMM's AI policy welcomes AI for bug finding and tests.

## Method

Build the branch at the pinned commit in a worktree under /Users/mas/code/wt, out of tree, with the Metal platform and the CPU and Reference platforms on. Run the Metal platform's ctest set once per chip with a per-test timeout. Record pass, fail, timeout or crash per test with the first failing assertion. For each failure, find the cause by reading the code and one minimal reproduction, and say "unexplained" when that does not settle it. Nothing in the branch is modified except in a separate patch file per proposed fix.

## Result

Pending.

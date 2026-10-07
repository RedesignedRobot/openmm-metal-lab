# 029: toward 2x OpenCL, and Folding@home readiness

Started 2026-09-25 from the 028 result. The target: Metal at half OpenCL's step time on every `benchmark.py` row on the M3 Ultra, with no regression on the M2. The second goal: show that a real Folding@home core can run a work unit on Metal.

## Where the work started

`research/distance-to-2x.md` has, per test and precision, how far the 8ae6cf17b build was from 2x and which kernel families would have to shrink. rf single was already past 2x. apoa1ljpme single needed 5.3% off the step, and gbsa single 30%. Host clock, M3 Ultra, OpenCL from the 028 window 2.

## M2 result at trunk 5071882fa

`lanes/results/r3-fah-m2-table/summary.txt`, M2 (10 GPU cores, 8 GB), `benchmark.py` host wall clock, median of 3 rounds of 30 s. Metal single against OpenCL single is 1.30x on gbsa, 1.51x on apoa1rf, and between those on the other seven rows. Metal mixed against OpenCL single is 1.215x to 1.353x. On six Folding@home-style units it is 1.10x (fah-gbsa) to 1.32x (fah-tip3p-hmr) in single. `M2-DENOMINATOR.json` has the same table for 7484d7bef, the 028 build, where Metal single was 1.153x to 1.329x and Metal mixed 0.914x to 1.165x.

## Folding@home readiness

`fah/GAPS.md` is the full account: the work-unit harness, force and energy checks along trajectories, constraints, nonequilibrium protocol work, restarts, a mixed-precision function audit, and a ranked list of open gaps. The pilot runs of 2026-09-28 passed as `nobody` under a LaunchDaemon at nice 19, through kill-and-resume tests, and through a 200,000-step soak with flat memory. Two of the gaps were bugs and are fixed: a mixed-precision reorder that rounded wrapped atoms to float (shared with CUDA, OpenCL and HIP), and an unclear failure for custom integrators that use a function df64 lacks. The main thing left is core signing. Under the hardened runtime, ad hoc signed plugins don't load, so Folding@home has to sign the core and every OpenMM library with one Developer ID, or link Metal statically. `fah/minicore/static.sh` builds the static version.

## Other checks

- `m4pro/README.md`: the trunk build from the M3 Ultra, copied unmodified to an M4 Pro. The forces gate and 58 of 58 core tests passed, and Metal beat OpenCL on every row.

## Layout

- `tools/`: build, gate, benchmark and profiling scripts (see `tools/README.md`).
- `fah/`: the Folding@home harness, minimal core, profiles and results.
- `research/`: the distance-to-2x table and a CPU count of PME spread atomics (`spreademu.py`).
- `lanes/results/`: raw data behind each change: benchmark JSON, `loads.txt`, `summary.txt`, force tables and profiles.

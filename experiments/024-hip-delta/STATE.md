# 024 run state

Hard stop: 08:00 UTC 2026-09-24, or after stage 4. Stop at the last commit that passes its gates.

Gates per commit: ctest -R TestMetal on par with `metal`, forces on par, benchmark.py on the M2 against `metal` 052eaa85b (host clock, median of 3 interleaved rounds), delta.sh.

Trees:
- laptop /Users/amir/code/mini/hipdelta, branch metal-hipdelta, pushed to `mini` only.
- laptop /Users/amir/code/mini/hipdelta-ref, detached at 052eaa85b (was 361452c5c). Mini ~/lab/hipdelta-ref builds it into venv-ref.
- Studio /tmp/openmm-metal-bench/hipdelta, deleted at the end.

Temporary knobs in the hipdelta working tree, never committed: HD_FASTMODE, HD_FASTFUNCS, HD_TBPC, HD_NBPC, HD_NBSIZE (HD_NOPOSTCOMMIT is gone with the fix commit). The permanent part of the fix commit is scratchpad fix-perm.patch.

Stage 4 is developed in the worktree /Users/amir/code/mini/hipdelta-mixed, local branch metal-hipdelta-mixed, now two commits on 62e1e2e95: 24aa12da2 (common code) and ea749ddb2 (Metal df64). Built and tested on the Studio as tree `mixed` (from WIP c306acf4b, same content). Fast-forward metal-hipdelta onto it only after the M2 gates.

## Progress

- [x] fix commit 62e1e2e95 made locally (README honesty, DisablePmeStream measured, 31-argument message and post-force commit cut). M2 ctest and forces running as of 03:00 UTC; push after they pass.
- [x] fix commit gates: M2 ctest 53/54 (anisotropic barostat, repeats 13/15 vs `metal` 12/15), forces identical, Studio 54/54. Pushed 62e1e2e95 to mini.
- [ ] stage 3
- [ ] stage 4
- [ ] report to the lead, Studio cleanup

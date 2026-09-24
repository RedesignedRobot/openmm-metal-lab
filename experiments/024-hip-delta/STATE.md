# 024 run state

Hard stop: 08:00 UTC 2026-09-24, or after stage 4. Stop at the last commit that passes its gates.

Gates per commit: ctest -R TestMetal on par with `metal`, forces on par, benchmark.py on the M2 against `metal` 052eaa85b (host clock, median of 3 interleaved rounds), delta.sh.

Trees:
- laptop /Users/amir/code/mini/hipdelta, branch metal-hipdelta, pushed to `mini` only.
- laptop /Users/amir/code/mini/hipdelta-ref, detached at 052eaa85b (was 361452c5c). Mini ~/lab/hipdelta-ref builds it into venv-ref.
- Studio /tmp/openmm-metal-bench/hipdelta, deleted 05:00 UTC and verified gone.

Temporary knobs in the hipdelta working tree, never committed: HD_FASTMODE, HD_FASTFUNCS, HD_TBPC, HD_NBPC, HD_NBSIZE (HD_NOPOSTCOMMIT is gone with the fix commit). The permanent part of the fix commit is scratchpad fix-perm.patch.

Stage 4 was developed in the worktree /Users/amir/code/mini/hipdelta-mixed (removed after the push), local branch metal-hipdelta-mixed, now two commits on 62e1e2e95: 24aa12da2 (common code) and ea749ddb2 (Metal df64). Built and tested on the Studio as tree `mixed` (from WIP c306acf4b, same content). Fast-forward metal-hipdelta onto it only after the M2 gates.

## Progress

- [x] fix commit 62e1e2e95 made locally (README honesty, DisablePmeStream measured, 31-argument message and post-force commit cut). M2 ctest and forces running as of 03:00 UTC; push after they pass.
- [x] fix commit gates: M2 ctest 53/54 (anisotropic barostat, repeats 13/15 vs `metal` 12/15), forces identical, Studio 54/54. Pushed 62e1e2e95 to mini.
- [x] stage 3: fast math mode (HIP's -ffast-math) screened +2 to 2.6 percent on the M2 but fails TestMetalConstantPotentialForce 3/3 (CG not converged). Commit b46bf2193 dropped, kept as local branch metal-hipdelta-fastmode, never pushed. Fast functions and M3 Ultra block shapes within noise. No stage 3 commit.
- [x] stage 4: 089374b36 (common) and b753d9a6a (Metal df64) pushed to mini metal-hipdelta. M2: 109/110 (flexible barostat, 4/5 repeats vs `metal` 4/5), `metal` 052eaa85b mixed 56/56, forces unchanged, single bench ratios equal 62e1e2e95's. M3 Ultra 110/110. Mixed benchmark vs 052eaa85b: 1.019 to 1.165.
- [x] Studio cleanup (05:00 UTC). Report to the lead sent at the end of the run.

## Round 2 (lead's messages after the report, 05:20 UTC)

Order: restore the 31-argument message (f341bf739), throw without a GPU core count (5d9e2388e), M3 Ultra tuning pass against `metal` 052eaa85b (keep a setting only if >= 0.97x `metal` on every benchmark on both chips; per-GPU branch <= 3 lines), apoa1ljpme spread on `metal` (5 fresh processes), then report. Stage 4 was already pushed before these messages arrived; the lead was told.

- [x] f341bf739 and 5d9e2388e: M2 ctest 108/110 from a git archive of HEAD, pushed to mini
- [x] Studio rebuilt at /tmp/openmm-metal-bench/hipdelta: trees hipdelta (knobs) and ref (052eaa85b)
- [x] M3 Ultra screens 1 and 2 (results/studio/screen-m3-1, -2) and M2 tiles screen (results/m2-tiles). Tiles 4 lifts rf and pme on the M3 Ultra and costs nothing on the M2. gbsa stays 0.87 to 0.90 on the M3 Ultra under every knob, so the tuning gate fails.
- [x] gbsa gap located (probes/split.py): GB kernels with NoCutoff are 1.02x `metal`; with the 2 nm cutoff GB-only is 0.82x. The gap is the HIP neighbor-list build, not the GB kernels. Not fixed.
- [x] apoa1ljpme spread: `metal` 128.4 to 129.6 over 5 fresh processes, hipdelta 88 to 158. Slow mode is per process, GPU side (cpu/wall 0.01 to 0.12), PME reciprocal only (apoa1rf steady). Gone with HD_NOSORT and with HD_RANGE1 (8/8 steady): HIP's multi-block computeRange in the bucket sort.
- [x] range fix commit (rangeKernelBlocks = 1): Studio screen, M2 ctest, forces, M2 bench, delta.sh, push
  - 9074c38f1 local, delta.sh 479/1,068 (results/delta-rangefix.txt). Gates started 06:28 UTC: M2 final.sh rangefix from a git archive of HEAD (scratchpad export-9074), Studio screen 5x15 s apoa1ljpme and apoa1pme, ref/head/range1.
- [x] README round 2 section, per-file table, risks, files list written (06:35 UTC). Split probe logs recovered into results/studio/split-probes.txt.
- [x] Studio dir deleted 07:58 UTC and verified gone; env, prefix, src, pr5434, verify-e4 left alone

## Round 2, late lead messages (06:37 UTC)

Two lead messages arrived after the round 2 work: restore the message (done, f341bf739), graceful AGX failure (done, 5d9e2388e), check the apoa1ljpme spread on `metal` and report whether it's ours but "don't fix it tonight", label tonight's Studio timings "owner away", rerun ctest Single+Mixed on both chips after items 1 and 2, write the M3 Ultra gap up as open, report, stop.

- [x] Spread is ours: `metal` 128.1 to 129.6 steady, 5d9e2388e 59 to 158. Cause found (multi-threadgroup computeRange). 9074c38f1 fixes it (apoa1ljpme 143.6 to 143.9, apoa1pme 191.1 to 193.7, results/studio/screen-rangefix) but stays local and unpushed per "don't fix it tonight". The lead decides.
- [x] README: "owner away" labels, gbsa gap written up as open with a hypothesis.
- [x] Studio ctest Single+Mixed: 5d9e2388e 110/110, 9074c38f1 110/110 (exact git archives synced over the knob tree, incremental builds)
- [x] M2 gates on 9074c38f1: ctest 110/110, forces identical, flexible 5/5 both trees, bench 1.001 to 1.181 vs `metal` 052eaa85b. Pushed 9074c38f1 to mini metal-hipdelta 07:56 UTC per the lead.
- [x] lab committed and pushed to mini main, report sent to the lead
- 06:45 UTC lead: push 9074c38f1 if its M2 gates pass; write the 157 figure up as a race artifact; recommend the numTilesInBatch line, don't commit it. README done for that.

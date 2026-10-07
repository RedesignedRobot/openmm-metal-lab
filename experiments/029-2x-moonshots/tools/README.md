# 029 tools

The 029 versions of the 028 tools (see `../../028-ultra-max/tools/README.md`), plus the M2 checks, the profiler and the GPU queue. They expect the same bench directory, `/tmp/openmm-metal-bench`, with these scripts in `ultra-tools/`. `install.sh` copies them there after the offline tests in `gpuq/tests/` pass. Each script's header comment is its full documentation.

The loop for one candidate on the M3 Ultra:

1. `sync.sh <worktree> <bench dir>` copies a working tree, uncommitted edits included, and keeps unchanged files' timestamps so builds stay incremental.
2. `build.sh <dir>` builds it like the reference tree.
3. `gate.sh --quick <dir>` checks forces against Reference. The full `gate.sh` adds every TestMetal test.
4. `ab.sh` screens it against a pinned baseline, and `summarize.py <outdir> mine/base` prints the median ratios. The clock is `benchmark.py`'s host wall time.
5. `m2cand.sh <worktree>` builds the candidate on the M2 over SSH, then runs the forces gate and an interleaved benchmark against the M2 base tree. The host comes from `hosts.env` in the bench directory (`M2=user@host`), which is not in this repository.

`window.sh` runs a full window, and `scoreboard.py <window outdir>` turns its `result.json` into a table of every Metal arm against OpenCL with the 2x count. `prof.py` and `gpuprof.sh` give per-kernel GPU time. `gpuq/` is the queue that hands the GPU to one timed job at a time; `lease.sh` is its command-line wrapper, and `lease-legacy.sh` the older lock it replaced.

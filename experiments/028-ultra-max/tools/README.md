# 028 tools

The scripts that built, checked and timed every 028 candidate on the M3 Ultra. They expect a bench directory at `/tmp/openmm-metal-bench`, with these scripts copied to `ultra-tools/` and a reference tree in `ultra-base/` (6df2b8bcb) that holds OpenMM's `examples/benchmarks` files. Each script's header comment is its full documentation.

- `sync.sh <worktree> <commit> <dir>` puts a commit's tree in `<dir>/src`.
- `build.sh <dir>` configures, builds and installs it the way `ultra-base` is built: Xcode-beta toolchain, Release, Metal, OpenCL, Python and tests on. It makes `<dir>/venv`, whose python imports that tree's openmm.
- `gate.sh [--quick] <dir>` is the correctness gate. `forces.py` compares Metal single and mixed forces and energy against Reference on six systems and checks them against `ultra-base/forces.txt`. Without `--quick` it also runs `ctest -R TestMetal`.
- `ab.sh <outdir> <rounds> <seconds> <tests> label=python:platform:precision ...` runs OpenMM's `benchmark.py` in interleaved rounds, each run in a fresh process, and logs the machine load before every run to `loads.txt`.
- `summarize.py <outdir> [num/den ...]` prints median ns/day per test and label, each label's rounds with their spread, and the ratios you ask for.
- `window.sh <outdir> <tests|all> <name=dir:precisions> ...` is a full benchmark window: a preflight that waits for a quiet machine, then `ab.sh` over every arm at 3 rounds of 30 s, then `summary.txt`. `--cpu` adds CPU platform baselines.
- `lease.sh` gives one command at a time the GPU, so no two timed runs share it.

`windows/w2.sh` is the exact script behind the 028 headline window, and `windows/w2/ab/configs.txt` records each arm's commit, source hash and toolchain.

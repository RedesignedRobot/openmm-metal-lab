# Shared tools for experiment 028

These live on the M3 Ultra in `/tmp/openmm-metal-bench/ultra-tools/`; this directory is the lab copy. Run them from there with absolute paths. Every tool prints its usage when called wrong, and each file's header says the same in more detail.

`ultra-<lane>` below is your scratch dir, `/tmp/openmm-metal-bench/ultra-<lane>`.

Host names live in `../hosts.env`, which git ignores: `STUDIO=<user@host>` and `M2=<user@host>`. sync.sh and the m2 scripts read it; source it in your shell (`. ../hosts.env` from here) before you copy an `ssh "$STUDIO"` line below.

## The loop

1. Commit on your branch, then on the laptop: `sync.sh <worktree> <commit> /tmp/openmm-metal-bench/ultra-<lane>`. It puts the commit's tree in `ultra-<lane>/src`, rewrites only files whose contents changed (so ninja rebuilds only those), and checks every file against git with `git hash-object`. This is the only laptop-side tool; run it from this directory.
2. On the Studio: `build.sh /tmp/openmm-metal-bench/ultra-<lane>`. It builds exactly like ultra-base: Xcode-beta's toolchain (it sets `DEVELOPER_DIR` itself and refuses if Xcode-beta is missing), `nice -n 10`, 6 jobs, Release, Metal, OpenCL, Python and tests on. It makes `build/`, `prefix/`, `venv/` and `logs/`, checks that all four platforms load from the venv, and writes `BUILT` with the commit, a hash of `src` and the compiler. A build dir configured with another SDK is removed and configured again. No lease needed. While a dedicated window runs (`/tmp/openmm-window` exists), build.sh waits for it to end before it touches anything.
3. `gate.sh --quick /tmp/openmm-metal-bench/ultra-<lane>`: forces against Reference compared with ultra-base, a minute or two. Screen a candidate only after it passes. The full gate (no `--quick`) adds `ctest -R TestMetal`, about 10 minutes of lease; it's for a candidate that screened at 3% or more, and for the integrated build.
4. `ab.sh`: the A/B screen against ultra-base.
5. `summarize.py <outdir> <num>/<den> ...`: medians, spreads, ratios.

Launch steps 2 to 4 detached through `/bin/sh`, so they run at nice 0 and survive an ssh drop:

```sh
ssh "$STUDIO" "/bin/sh -c 'nohup /tmp/openmm-metal-bench/ultra-tools/gate.sh --quick /tmp/openmm-metal-bench/ultra-<lane> > /tmp/openmm-metal-bench/ultra-<lane>/gate.out 2>&1 < /dev/null &'"
```

Then wait on the `.out` file in the foreground (Monitor, or a `until grep -q ...; do sleep 30; done` loop).

## The lease

`lease.sh` is a first come, first served queue. gate.sh takes one hold for the whole gate and ab.sh one for the whole screen, so don't hold the lease when you call them: a hand-made `mkdir /tmp/openmm-lease` around them waits on itself forever. For your own GPU work (profiles, one-off runs) use lease.sh instead of `mkdir`:

```sh
/tmp/openmm-metal-bench/ultra-tools/lease.sh ultra-<lane> "what you're running" <command...>
/tmp/openmm-metal-bench/ultra-tools/lease.sh --status
```

- Each caller queues a ticket in `/tmp/openmm-lease-queue`, named `<microseconds>-<lane>-<pid>`, and gets the lease when its ticket is the oldest live one and the lease is free. The ticket at the head polls every 0.1 s, the rest every second. Files in the queue with any other name are ignored.
- The lease never waits for builds. A timing hold that starts while a build (`clang`, `clang++`, `ninja` or `cc1plus`) runs gets BUILD RUNNING in the owner line, and ab.sh marks such runs in loads.txt. Screens tolerate that (RULES.md, How the program runs); a dedicated window has no builds.
- `--correctness` (first argument) marks work whose result doesn't depend on timing: forces, ctest, drift, force dumps. Correctness holds share the GPU. When the ticket at the head is `--correctness` and the lease is a correctness hold with fewer than 3 members, it joins that hold. A timing ticket waits for an empty lease, and nothing queued behind it joins, so timings stay exclusive and nothing overtakes. Never use `--correctness` for a timing or a profile.
- The command runs in its own process group. At 20 minutes, lease.sh stops the whole group (TERM, then KILL 10 s later) and leaves the hold. Killing lease.sh stops the group too. Keep each command well under 20 minutes. gate.sh's one hold has a 45 minute cap.
- A lease.sh inside another one runs its command at once, inside the outer hold and its cap. gate.sh and ab.sh go through lease.sh once themselves, so inside window.sh or your own lease.sh call they queue nothing.
- An outer timing hold whose GPU reads under 10% for 60 s straight (the lead's ioreg "Device Utilization %", every 5 s) gets one warning line on the holder's stderr and in `/tmp/openmm-lease-idle.log`, and another after the GPU has been busy. Correctness holds, nested calls and the window are exempt. A timing hold carries only timing.
- `--status` prints the holder, how long it has held the lease, the members of a shared correctness hold, the number of build processes, the queue in order, and a count of ignored files.
- A ticket or holder counts as live only while its pid runs lease.sh, since a dead pid can be reused. Dead tickets, dead holders and dead members are cleared. A lease taken by hand (no pid file) is cleared once it is older than 21 minutes; don't take one.
- Lead and infra only, never lanes: `LEASE_TICKET_US=<16 digits>` dates the ticket instead of the clock. Its one use is keeping a restarted job's original place in the queue, and window.sh's ticket just ahead of the queue. `--cap SECONDS` replaces the 20 minute cap, for window.sh's hold. A lane that dates its own ticket jumps every job queued before it.

## gate.sh

`gate.sh [--quick] <dir>`, where `<dir>` is a build.sh tree (its `venv` path works too). It refuses to run at a nice value other than 0, when `BUILT` is missing, or when `src` changed after build.sh.

- Forces: `forces.py` evaluates Metal single and mixed against Reference (double) on gbsa, rf, pme, apoa1rf, apoa1pme and apoa1ljpme. Reference forces at the starting positions come from `ultra-base/reference/<test>.npz`, written from ultra-base, so the hold covers only the Metal evaluations. A row fails when rel|dF|, rounded to 3 digits, is above ultra-base's (`ultra-base/forces.txt`), or when rel|dE| is more than 10 times ultra-base's. rel|dF| repeats to 4 digits on one build, so the first check is the RULES.md gate. Single precision rel|dE| moves between runs (apoa1rf read 4.04e-8 on the CLT build and 5.65e-8 on the beta build, with identical rel|dF|), so its check only catches breakage.
- ctest, full gate only: `ctest -R TestMetal -j2 --timeout 600 --output-on-failure`, split round-robin into parts of at most 30 tests, each run by gate-ctest.sh. Forces and every part run inside the gate's one correctness hold (cap 45 minutes; the plugins tree's 134 tests took 1177 s), so a full gate queues once. Other correctness tickets join that hold, up to 3 members. Every listed test must have run.
- A failed statistical test reruns alone up to 3 times, in the same hold, and passes if a rerun passes. The line says which, for example `ok TestMetalMonteCarloAnisotropicBarostatSingle failed in the -j2 run, pass on rerun 2/3`. Statistical means TestMetal MonteCarloFlexibleBarostat, MonteCarloAnisotropicBarostat, MonteCarloBarostat, LangevinIntegrator, LangevinMiddleIntegrator, VariableLangevinIntegrator or CustomIntegrator, Single or Mixed, or a failure whose output says "This test is stochastic and may occasionally fail" (OpenMM's own marker). RULES.md names FlexibleBarostat and LangevinIntegrator; the rest failed at similar rates on both trees in experiment 024 or on ultra-base and the plugins tree.
- Any other failure fails the gate. It reruns once alone, and the line says whether it "passes alone" (a flake, or interference from the second test process) or "fails alone too". A change to integrators, barostats, random numbers or their reductions gets 10 runs of the statistical tests on candidate and base from the integrator lane.
- Logs: `<dir>/gate-<time>/` holds forces.txt, forces-verdict.txt, tests.txt, and per part tests-N.txt, ctest-N.txt and verdict-N.txt, plus each rerun.

## The stale-list check

The forces gate evaluates a fresh Context once, so it never sees a stale neighbor list. A change to padding, the rebuild trigger or neighbor-list contents also runs the 100-step check (RULES.md, How the program runs):

```sh
/tmp/openmm-metal-bench/ultra-tools/lease.sh --correctness ultra-<lane> "md100 forces" \
    /tmp/openmm-metal-bench/ultra-<lane>/venv/bin/python /tmp/openmm-metal-bench/ultra-tools/forces.py --md 100 \
    /tmp/openmm-metal-bench/ultra-base/benchmarks /tmp/openmm-metal-bench/ultra-<lane>/md100.txt /tmp/openmm-metal-bench/ultra-base/forces-md100.txt
```

Each Metal Context runs 100 steps of benchmark.py's LangevinMiddleIntegrator (4 fs, 300 K, fixed seeds), then its forces are compared with Reference at the positions it reached. Trajectories differ between builds, so a row fails only when rel|dF| or max|dF| is more than twice ultra-base's.

## ab.sh

```
ab.sh [--rerun-builds] <outdir> <rounds> <seconds> <tests|all> <label=python:platform:precision[:VAR=value,...]>...
```

- `<outdir>` is absolute and new (it refuses a non-empty one). Put it under your scratch dir, `/tmp/openmm-metal-bench/ultra-<lane>/`, so the ticket names your lane; for an outdir elsewhere, set `AB_LANE=ultra-<lane>`.
- `<tests>` is a comma list or `all` (gbsa, rf, pme, apoa1rf, apoa1pme, apoa1ljpme, amber20-dhfr, amber20-cellulose, amber20-stmv).
- Each configuration is a label, a venv python, `Metal:single`, `Metal:mixed`, `OpenCL:single`, `CPU:single` or `CPU:mixed`, and optional environment settings for that run, comma separated. Labels may use letters, digits, `.`, `_` and `-`.
- Every run is a fresh process. Within a test the configurations run back to back, reversed every other round.
- The whole screen is one timing hold: ab.sh queues one ticket and runs every (round, test) inside it.
- It prints an estimate first: each run is `<seconds>` plus that test's setup on the M3 Ultra (4 s for gbsa, rf, pme and dhfr, 6 s for apoa1, 12 s for cellulose single and 47 s mixed, 60 s for stmv, 15 s for amoebagk, 20 s for amoebapme), and twice `<seconds>` on the CPU platform. A screen over 18 minutes is refused before it queues, since lease.sh stops a hold at 20: split it by test into several ab.sh calls. window.sh's screen is exempt.
- Before each run it logs the load averages, the Hyperscale VM's CPU (`vm N%`) and the top 5 CPU processes to `loads.txt`. A run that starts with a build running, or during which a build starts (checked once a second), is marked BUILD RUNNING there, and summarize.py lists those runs.
- `--rerun-builds` (first argument, used by window.sh) reruns every (round, test) that has a marked run once at the end, all configurations in that round's order. The replaced results move to `<outdir>/replaced`.
- All runs use ultra-base's benchmarks dir, so every build times the same benchmark.py and inputs.
- It refuses a build.sh tree with no `BUILT` or whose `src` changed after the build, and records each configuration's openmm path and `BUILT` in `configs.txt`.
- A run that writes no result (benchmark.py skips a test whose context throws) is logged as NO RESULT. A run over `<seconds>` + 900 s is killed.

The RULES.md screen, 2 rounds of 15 s:

```sh
/tmp/openmm-metal-bench/ultra-tools/ab.sh /tmp/openmm-metal-bench/ultra-<lane>/screen1 2 15 gbsa,rf,pme,apoa1rf,apoa1pme,apoa1ljpme \
    base=/tmp/openmm-metal-bench/ultra-base/venv/bin/python:Metal:single \
    mine=/tmp/openmm-metal-bench/ultra-<lane>/venv/bin/python:Metal:single
```

Add the mixed configurations if your change touches mixed precision. To compare a knob, give the same python twice with different settings: `knob=/tmp/openmm-metal-bench/ultra-<lane>/venv/bin/python:Metal:single:MY_KNOB=4`.

## summarize.py

```
/tmp/openmm-metal-bench/ultra-base/venv/bin/python /tmp/openmm-metal-bench/ultra-tools/summarize.py /tmp/openmm-metal-bench/ultra-<lane>/screen1 mine/base
```

Prints median ns/day per test and label, each label's rounds with their spread ((max-min)/median), and for each `num/den` pair the ratio of medians with the lowest and highest single-round ratio. Then the 1 minute load range, the Hyperscale VM's CPU range, any run with no result, and any run that overlapped a build. A (round, test) that `--rerun-builds` ran again drops out of the last two lists. A ratio whose round range straddles 1.0 isn't a win yet.

## stoch.sh

```
stoch.sh <outdir> <runs> <ctest regex> <dir>...
```

For a candidate that changes integrators, barostats, random numbers or their reductions: runs `ctest -R <regex> -j2` `<runs>` times on each build.sh tree (base first, then the candidates), one lease hold per repetition (`--correctness`) covering every dir, order reversed every other repetition. `<outdir>/counts.txt` has, per dir, how many runs finished and how often each test failed. Pick the regex for the change and keep one repetition well under 20 minutes; the barostat tests take 30 to 130 s each, LangevinMiddleIntegrator under 10 s.

## window.sh (lead and infra only)

```
window.sh [--estimate] [--cpu] [--rounds N | --smoke] <outdir> <tests|all> <name=dir:precisions>...
```

The dedicated window from RULES.md. Lanes never call it.

- It queues with a ticket dated just before the oldest queued ticket, so it starts the moment the current hold ends, and every queued ticket keeps its place behind it. It holds the lease for the whole window, capped at twice the estimate plus 20 minutes, so no lane's GPU work runs meanwhile. Called inside a lease.sh hold, it runs in that hold instead of queueing.
- While it holds the lease, `/tmp/openmm-window` names its pid, start time and outdir. build.sh waits for it to end, and lanes queue nothing new. Nothing that is already running gets stopped: Hyperscale's VM and other agents run on and are logged.
- Every run logs the load and the Hyperscale VM's CPU first. A (round, test) with a run that overlapped a build runs again at the end (ab.sh `--rerun-builds`), and summary.txt lists any run that still overlapped one.
- Preflight, inside the hold: it waits up to 10 minutes for the 1 minute load to fall under 3 with no build processes, then starts anyway and says so. `<outdir>/preflight.txt` logs the wait, the queue and the top CPU processes.
- Each build is `name=dir:precisions`, with precisions from single, mixed and opencl. The first build is the baseline. ab.sh runs every configuration interleaved, 3 rounds of 30 s. `<outdir>/summary.txt` has each Metal configuration against the baseline's OpenCL, and each other build against the baseline's same precision. A winner alone is one more build, for example `pme=/tmp/openmm-metal-bench/ultra-pme:single,mixed`.
- `--cpu` adds the CPU baselines after the screen, still inside the hold: 1 round of `<seconds>` s of pme and apoa1pme on the baseline build's CPU platform (mixed), into `<outdir>/cpu` with `cpu-summary.txt`. The first window runs it once; it adds about 2 minutes.
- `--estimate` prints the expected wall time and exits. `--smoke` is 1 round of 5 s with at most 1 minute of preflight.

```sh
ssh "$STUDIO" "/bin/sh -c 'nohup /tmp/openmm-metal-bench/ultra-tools/window.sh --cpu /tmp/openmm-metal-bench/ultra-infra/w1 all \
    base=/tmp/openmm-metal-bench/ultra-base:single,mixed,opencl int=/tmp/openmm-metal-bench/ultra-integrated:single,mixed \
    > /tmp/openmm-metal-bench/ultra-infra/w1.out 2>&1 < /dev/null &'"
```

That is the first window; later windows drop `--cpu`.

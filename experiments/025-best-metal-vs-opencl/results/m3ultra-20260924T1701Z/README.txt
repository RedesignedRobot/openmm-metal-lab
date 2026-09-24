M3 Ultra (Mac Studio, 60-core GPU, macOS 27.2), 2026-09-24, owner at the machine with light use.
Hostnames in every file were replaced with "M3 Ultra". All tests and timings ran at nice 0
(results/machine.txt, the "nice" field in baro/summary-*.txt), launched through /bin/sh -c, holding
/tmp/openmm-lease. A first launch at nice 15 was killed before any test or timing finished; its partial
output was deleted (logs/progress-niced-aborted.txt). A two-arm barostat attempt was stopped after 1 run
when the lead asked for the 9074c38f1 control (logs/baro-aborted-2arm, logs/progress-aborted-2arm.txt).
Only the builds ran niced.

Trees, each a git archive checked file by file against git (git hash-object on all ~2,478 files):
  hd     6df2b8bcb (metal-hipdelta-gbsa, event wait). Barostat used evwait's existing build of it; the
         Python/OpenCL build for benchmark.py and forces is a fresh one (build.sh hd).
  p9074  9074c38f1, the direct parent of 6df2b8bcb (build.sh p9074, test binary only).
  ref    052eaa85b, the hand-written metal platform (build.sh ref, test binary only). The M2's
         ~/lab/hipdelta-ref holds this tree, not 9074c38f1.

1. TestMetalMonteCarloFlexibleBarostat (baro.sh; interleaved, order reversed every other run)
   single, 10 per arm: hd 8/10, p9074 9/10, ref 10/10
   mixed,   5 per arm: hd 5/5,  p9074 4/5,  ref 5/5
   Failures (baro/<arm>-<precision>-<i>.txt), all flagged by the test as stochastic:
     hd single 1:     TestMonteCarloFlexibleBarostat.h:237  Expected 0, found 0.431885
     hd single 4:     TestMonteCarloFlexibleBarostat.h:105  Expected 3, found 3.62867
     p9074 single 10: TestMonteCarloFlexibleBarostat.h:237  Expected 0, found -0.441985
     p9074 mixed 5:   TestMonteCarloFlexibleBarostat.h:237  Expected 0, found -0.509719

2. Forces against Reference (fcheck.py, adapted from ../../forces.py; results/forces.txt)
   rel|dF| per system, identical across Metal single, Metal mixed and OpenCL single to 3 digits:
   gbsa 2.47e-05, rf 2.21e-05, pme 2.05e-05, apoa1rf 5.99e-05, apoa1pme 7.75e-05, apoa1ljpme 7.75e-05.
   rel|dE| 4.1e-07 to 1.2e-06 on the PME systems, 4.9e-08 to 6.3e-07 elsewhere.

3. benchmark.py, 6df2b8bcb, ab.sh protocol: 3 rounds, 30 s, a fresh process per run, configuration order
   reversed every other round, load logged before each run (results/bench/loads.txt). ns/day measured
   by benchmark.py's host clock (datetime.now() around step(), with a getState() sync). Medians:

   test               Metal single  Metal mixed  OpenCL single  single/OpenCL  mixed/OpenCL
   gbsa                    1272.56       842.61        1177.80          1.080         0.715
   rf                       717.60       481.47         670.19          1.071         0.718
   pme                      542.17       401.66         525.06          1.033         0.765
   apoa1rf                  301.27       243.72         282.37          1.067         0.863
   apoa1pme                 194.74       168.59         182.40          1.068         0.924
   apoa1ljpme               144.84       129.30         128.30          1.129         1.008
   amber20-dhfr             577.06       415.81         568.36          1.015         0.732
   amber20-cellulose         54.36        49.00          48.14          1.129         1.018

   python3 summarize.py results/bench metal-single/opencl-single metal-mixed/opencl-single prints the
   rounds. The largest spread within a configuration is 2.1 percent (metal-mixed rf). The 1 minute load
   before the 72 timed runs was 1.72 to 4.68; no run started above 6.
   amber20-stmv was not run: run2.sh was prepared, but the lead asked for results first.

   OpenCL mixed: benchmark.py printed "No compatible OpenCL platform is available"
   (results/opencl-mixed.txt). OpenCLContext.cpp skips every device without cl_khr_fp64 in mixed or
   double precision. clfp64.c queries the device directly (results/opencl-fp64.txt): Apple M3 Ultra,
   OpenCL 1.2, cl_khr_fp64 absent, CL_DEVICE_DOUBLE_FP_CONFIG 0x0.

Files: run.sh (driver), baro.sh, build.sh, fcheck.py, ab.sh and summarize.py (copies of ../../),
run2.sh (not run), clfp64.c, logs/ (progress.txt, ab.log, gzipped build logs), results/, baro/.

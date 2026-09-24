Screening on the M2 (Mac mini, 10 GPU cores, 8 GB) before the full run. Clock: benchmark.py's host wall
clock. Hostnames in every file were replaced with "M2".

langevin.txt      TestMetalLangevinIntegratorMixed, 5 runs each, interleaved: ~/lab/hipdelta/build (6df2b8bcb)
                  and ~/lab/hipdelta-ref/build (`metal` 052eaa85b). 5 of 5 pass on both. Ran at NI 5.
phase1.log        The Langevin reruns, then the build of the screening tree (6df2b8bcb plus temporary FB_*
                  environment knobs, never committed) and venv-base (the 6df2b8bcb module). NI 5.
screen1-forces.txt  forces.py on the screening build for each knob setting, Metal single against Reference
                  (double). rel|dF| is the same to 4 digits for every setting. NI 5.
screen1/          1 round of 15 s per setting, 5 tests, fresh process per run. NI 5 on every run.
                  1 minute load 1.56 to 4.38. Labels: base = 6df2b8bcb; scr = screening build, no knobs;
                  t64 / t256 = FB_TGS (findBlocksWithInteractions threadgroup size, default 32);
                  p0 = FB_P0=1 FB_TGS=256 (exp 019's P0 kernel body with HIP's signature, 256 threads,
                  one threadgroup per 8 block1 rows); p0g120 = p0 as a persistent grid of 120 threadgroups.
screen1.run.log   stdout of screen1.sh including the summary.
screen2/          2 rounds of 15 s, 4 tests, NI 0 on every run. 1 minute load 1.20 to 2.51.
                  base = 6df2b8bcb; bits0 = screening build with FB_BITS=0 (no single pairs);
                  p0metal = `metal` 361452c5c + P0 (branch metal-simd-findblocks 33728aa53, exp 019's
                  install ~/lab/prefix-openmm-simd, read-only).
screen2.run.log   stdout of screen2.sh including the summary.

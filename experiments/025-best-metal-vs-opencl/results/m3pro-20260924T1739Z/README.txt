benchmark.py on the M3 Pro (18 GPU cores, MacBook Pro 16), branch metal-hipdelta-gbsa at 6df2b8bcb.
Clock: benchmark.py's host wall clock (datetime.now() around step() plus a getState() sync).

ac/               The run to quote. AC power, nice 0, under caffeinate -i. 3 rounds x 8 tests x 3
                  configurations, --seconds 30 (timed segments 29.5 to 32.9 s), one fresh process
                  per run, order reversed in round 2. 72 of 72 runs wrote a result. 1 minute load 1.16 to 3.39.
                  summary.txt has the medians, every round and the ratios.
battery-partial/  The first attempt: battery power (51% down to 23%), nice 10. Rounds 1 and 2 complete,
                  round 3 stopped at rf metal-single (that file holds an empty benchmark list). Its medians
                  agree with ac/ within 1.7% on every test and configuration.
checks/           forces.txt: Metal single, Metal mixed and OpenCL single against Reference on the six small
                  systems. opencl-precision.txt: OpenCL refuses mixed and double on this Mac.
                  barostat-mixed-*: TestMetalMonteCarloFlexibleBarostat mixed, 5 runs.
build/            Build script, configure logs, toolchain provenance.
ab.sh             025's ab.sh with two additions: the battery state on every loads.txt line, and a guard
                  that refuses to run at a nonzero nice value (added for the AC run).
Hostnames in every file were replaced with "M3 Pro".
battery-vs-ac.txt Per-run battery/AC ratios by round, next to the AC round-to-round spread.
Priority: the build, forces check, OpenCL precision probe and the 5 barostat runs all ran at nice 10.
None of them is a timing. Every run in battery-partial/ was timed at NI 10. Every run in ac/ was
timed at NI 0.

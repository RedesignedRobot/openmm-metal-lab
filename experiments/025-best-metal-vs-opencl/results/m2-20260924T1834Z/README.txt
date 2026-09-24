M2 benchmark.py run, 2026-09-24 18:34Z, by the best-metal agent.

Conditions: AC power, nice 0 (checked by the chain), 3 rounds of 30 s, configurations interleaved per test.
Clock: benchmark.py's host clock (datetime.now() around step()). Statistic: median of rounds.
Hostnames were replaced with "M2".

Builds:
- metal-single and metal-mixed: hipdelta 6df2b8bcb (the event-wait fix).
- metalp0-single: branch `metal` 052eaa85b plus the P0 change.
- opencl-single: the OpenCL platform from the 6df2b8bcb build.
OpenCL has no mixed on Apple GPUs (no cl_khr_fp64).

Medians, ns/day (summary.txt has every round):

test               Metal single  Metal mixed  OpenCL single  single/OCL  mixed/OCL
gbsa                     414.15       320.67         381.47       1.086      0.841
rf                       253.90       178.78         255.76       0.993      0.699
pme                      207.65       154.85         196.91       1.055      0.786
apoa1rf                   69.30        53.70          59.33       1.168      0.905
apoa1pme                  54.13        44.15          46.03       1.176      0.959
apoa1ljpme                40.05        34.35          34.03       1.177      1.010
amber20-dhfr             216.09       158.63         209.96       1.029      0.756
amber20-cellulose         11.69        10.00          10.26       1.139      0.974

metal+P0 against hipdelta, single: rf 1.100, apoa1rf 1.068, cellulose 1.053, pme 1.041,
apoa1pme 1.037, apoa1ljpme 0.961, gbsa 0.938. amber20-dhfr is missing for metalp0 (that run lacked scipy).
The M2 screen2 result holds at 3 rounds: `metal` plus P0 beats hipdelta on the cutoff tests and loses on gbsa and ljpme.

Forces against Reference: m2-full/checks/forces.txt (Metal single and mixed match OpenCL to the third digit of rel|dF|).
Also here: m2-screen3 (a 1-test screen), screen2 (the 2-round screen), langevin.txt (Langevin 5/5 reruns).

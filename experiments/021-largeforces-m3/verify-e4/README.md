# Independent check of #5434 (verify-e4)

A fresh-context verifier's own probes, separate from the 021 lane.

- probe.swift: Metal kernel probe of float to int/uint/long/ulong conversions. Outputs m3u-probe.txt (M3 Ultra) and m2-probe.txt (M2).
- clprobe.c: OpenCL probe (-cl-mad-enable -cl-no-signed-zeros) of `(long)(x*2^32)`, `convert_long_sat(x*2^32)` and `(long)x`. Output m3u-clprobe.txt, M3 Ultra, 2026-09-23 16:28Z under the Studio lease.

Result: on M3 Ultra, `(long)(x*2^32)` wraps mod 2^64 (2^31 gives 8000000000000000, 2.18e22 gives 0). `convert_long_sat` saturates every out-of-range input, keeps in-range values exact, and maps NaN to 0. This backs openmm/openmm#5435. The M2 OpenCL probe did not run (mini lease busy); M2 saturation under Metal is in m2-probe.txt.

# Head note on 011

The lane's headline, "PME pipeline 4.05x faster on Metal", is struck. It compared unlike clocks.

## What was wrong

The lane timed each OpenCL kernel as host wall time around `clEnqueueNDRangeKernel` plus `clFinish`. It timed each Metal kernel as `gpuEndTime - gpuStartTime`. Apple's `clFinish` round trip costs about 0.3 ms on the M2, so a 0.014 ms kernel read as 0.348 ms. The FFT comparison had the same flaw: Metal reported GPU time, OpenCL reported wall time.

## What I changed

OpenCL kernels now report profiling event time, converted from mach ticks with `mach_timebase_info` (experiment 008). Both VkFFT backends now report wall time over 32 transforms per sync. The agreement checks still run single transforms. The gate exits 0 on both chips, and the results JSON files here come from that rerun. The tables in `results.md` and `README.md` that quote OpenCL times predate the fix.

## Like-for-like result, median of 25, ms

| Kernel | M2 OpenCL | M2 Metal | M3 Ultra OpenCL | M3 Ultra Metal |
| --- | --- | --- | --- | --- |
| findAtomGridIndex | 0.014 | 0.016 | 0.008 | 0.014 |
| gridSpreadCharge, fixed point | 0.637 | 0.940 | 0.408 | 0.412 |
| gridSpreadCharge, float atomics | none | 0.832 | none | 0.169 |
| finishSpreadCharge | 0.159 | 0.152 | 0.022 | 0.020 |
| reciprocalConvolution | 0.034 | 0.036 | 0.016 | 0.015 |
| gridInterpolateForce | 0.182 | 0.184 | 0.035 | 0.036 |
| VkFFT forward | 0.204 | 0.193 | 0.068 | 0.067 |
| VkFFT inverse | 0.201 | 0.178 | 0.064 | 0.064 |

PME is a tie. The translated kernels run at OpenCL speed and VkFFT runs at the same speed on either API, with Metal 5 to 11% ahead on the M2 FFT. The one Metal gain is float atomics spreading on the M3 Ultra: 0.169 ms against 0.432 ms for fixed point plus finishSpreadCharge, 2.6x. On the M2 float atomics lose to OpenCL fixed point, 0.832 against 0.796 ms with the finish step.

The M2 fixed-point spread on Metal has an IQR of 0.17 ms around 0.94 ms, and the lane's first run measured 0.653 ms. That spread is unexplained, so I do not quote a ratio for it.

## Accepted

Agreement within 0.54 ppm for every PME kernel on both chips, with 11 mutations that turn the gate red. VkFFT works on Metal through metal-cpp without Xcode. MPSGraph FFT is 4 to 7x slower than VkFFT and is not a candidate. The gather formulation of spreading is 8 to 30x slower and is dead.

## Rule for later experiments

Every timing table names its clock per column. Two APIs are compared on the same clock or not at all.

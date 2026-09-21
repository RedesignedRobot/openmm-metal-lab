# Head's note on this census

The lane's files label five programs "compiles with unsafe placeholder" because they accumulate into 64-bit fixed-point buffers through a split-word atomic add. That label came from the head's brief and it is wrong. The split-word add is OpenMM's own code from `platforms/opencl/src/kernels/common.cl`, it is exact for pure accumulation, and `experiments/004-msl-probes/split-word-atomic-add.swift` shows it exact in MSL under heavy contention on the M2 and the M3 Ultra. Read the census as: 26 of 26 programs compile and build every pipeline state on both chips, with two mechanical rewrites.

Still open: nothing here has run. Numerical agreement with the OpenCL platform is the next experiment.

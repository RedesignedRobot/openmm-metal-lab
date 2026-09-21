# Head note on 012

Accepted. The clocks are named per column and matched: event time against GPU timer for single kernels, 32-batch wall time for whole sorts. The gate log shows all five mutations red and zero mismatches.

Sort and the utility kernels tie with OpenCL on both chips. The translated bucket sort is the design to keep. The native bitonic sort is 1.5 to 2.9x slower and is dropped.

Not accepted as findings: per-kernel ratios under 0.02 ms where the IQR is a third or more of the median (assignElementsToBuckets2 on the M3 Ultra, reduceEnergy and computeBucketPositions on the M2). Those are noise. The lane's complexity argument for why bitonic loses is reasoning, not an ablation; the measured times stand on their own.

Useful fact for the host layer: upstream has no GPU atom reorder. reorderAtomsImpl sorts on the CPU and uploads, then setCharges permutes charges on the GPU. A Metal platform inherits that through Common Compute unchanged.

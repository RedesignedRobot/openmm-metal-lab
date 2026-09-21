# Head's note on 009

Accepted. This is the lab's first performance result, and it is the one the upstream thread asked for: on real ApoA1 buffers captured from a running simulation, a findBlocksWithInteractions that uses `simd_ballot`, `ctz`, `popcount` and `simd_broadcast` runs 2.33x (rf) and 2.36x (pme) faster than Apple's OpenCL on the M2, and finds the identical interaction set. The straight translation of the OpenCL source gains nothing (8% slower on the M2), so the win comes from the SIMD-group functions and not from the API.

What the head checked:

- Mutation. Shrinking the native kernel's atom cutoff by 2% makes the gate fail with 40,712 pairs missing, while the OpenCL and translated rows stay at zero difference. The comparison tests the native kernel's own output.
- The kernel's layout assumption. It takes `local_id % 32` as the lane and expects bit i of the ballot to be lane i. `experiments/004-msl-probes/simd-alignment.swift` confirms both, and a SIMD width of 32, for threadgroup sizes 32 to 512 on both chips with zero exceptions in 92,224 threads. A version for upstream should still read `[[thread_index_in_simdgroup]]` and `[[threads_per_simdgroup]]` and refuse to run if the width is not 32, because Apple documents neither fact as a guarantee.
- Timing method. The translated Metal kernel and the OpenCL kernel time within 2% of each other on the M3 Ultra through two different timestamp sources, so the two clocks agree.
- The mini's baseline OpenMM install is back in place after the capture build.

Caveats:

- Lanes in a SIMD group read threadgroup memory that a sibling lane wrote in the same iteration (`buffer[...]`) with no barrier between. The OpenCL original does the same behind its SYNC_WARPS macro, which is empty on lockstep hardware. It gives the right set here on every run; it rests on lockstep execution inside a SIMD group, which Apple does not promise in writing.
- What it means for a whole simulation, by Amdahl from experiment 003's M2 fractions: about 1.24x on apoa1rf and 1.17x on apoa1pme if nothing else changes. Those fractions are of GPU kernel time. An end-to-end number needs a running platform.
- Not exercised: triclinic boxes, large blocks, the sort between the key and box kernels, systems other than ApoA1.
- The capture patch (openmm-capture.patch) also wrote computeNonbonded's buffers. Experiment 010 starts from them.

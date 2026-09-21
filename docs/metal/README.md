# Metal reference notes

Seven notes written by two Gemini research lanes on 2026-09-21, against macOS 27.0 and the MSL 4.1 specification. They are working notes, not verified fact. Each note cites sources; the head has checked only the claims listed below. Before a design decision rests on a claim, check its citation or write a probe in `experiments/004-msl-probes`.

| Note | Covers |
| --- | --- |
| `msl-for-compute.md` | Kernel arguments, address spaces, SIMD-group functions, atomics, integer widths, math modes, specialisation |
| `metal4-api.md` | Metal 4 command model against the classic one, storage modes, hazard tracking, synchronisation |
| `metal-cpp.md` | metal-cpp, its C++17 requirement, a way to confine it to private files. `examples/metal-cpp-min` builds with the Command Line Tools alone |
| `profiling-without-xcode.md` | GPU timing and validation available without Xcode |
| `mlx-metal-backend.md` | How Apple's MLX and ggml's Metal backend batch commands, compile kernels and allocate buffers |
| `apple-gpu-architecture.md` | Apple GPU microarchitecture from M1 to M5 |
| `prior-art-md-on-metal.md` | philipturner's plugin, NORPG's branch, other molecular dynamics on Metal |

## Audit status

Checked by execution (see `experiments/004-msl-probes`):

- Program-scope thread builtins work. Confirmed on M2 and M3 Ultra.
- `simd_ballot` exists. Confirmed on both.
- Float atomics: `msl-for-compute.md` says Apple7 and later, `apple-gpu-architecture.md` and `prior-art-md-on-metal.md` say Apple9 and later. The probe says they build and give right answers on the M2, and cost 560 times more than on an M3 Ultra under worst-case contention. Read both notes with that in mind.
- 64-bit accumulation: the split-word add from OpenMM's OpenCL prelude is exact in MSL under contention on both chips, and about 150 times cheaper per add than a float atomic on the M2.
- Native 64-bit atomics: the claim in `msl-for-compute.md` (min and max on Apple8, full arithmetic on Apple9) failed to compile on both chips. Treat as wrong until shown otherwise.

Not yet checked, and carrying suspiciously exact numbers: the per-dispatch firmware latency (10 to 25 microseconds), the SETTLE and half-spectrum PME speedups, and the threadgroup sizing advice in the implementation lane's notes. The API lane reported "nothing unverified", which is not believable for four notes of this size.

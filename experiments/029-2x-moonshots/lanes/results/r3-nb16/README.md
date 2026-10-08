# 16x32 direct-force experiment

Verdict: reject. apoa1rf padded q is 0.731345, but paired force captures measured
1.13328 times the total dynamic instructions and 1.85227 times the force time.
Temporary registers rose from 59 to 66 and occupancy target fell. No GPU emitter,
production selection, host keep measurement or final acceptance gate was attempted
after this kill. See `counter-summary.json` and `../../r3-nb16.md` for the full report.

Base: `0b7a7b3400b99eb040301b492505e7f17f7d3894`, branch `r3/nb16`.
Build: `/tmp/openmm-metal-bench/ultra-r3-nb16`, synced and built with the installed tools.
Prototype commit: `f7dc3e27d`, no push. The source manifest matches the measured build.

`snapshot.cpp` uses the same public Metal context access as `ultra-tools/listcheck.cpp`.
It downloads live direct-force positions, the ordinary tile x indices, all 32 receiver
indices per ordinary tile, exceptional tiles, single pairs, atom order and box vectors.
It rejects truncated lists. It changes no platform state and adds no environment switches.

`capture.py` creates the systems from the installed benchmark definitions. It uses the
benchmark's 4 fs LangevinMiddle setup with seed 2026, then completes a force evaluation
before each download. Coordinates in each snapshot are the reordered float4 positions
read by the direct-force kernel, including for mixed precision. Snapshots contain the
build stamp and benchmark source hash. The cutoff skin is the baseline's 8 percent.

`emulate.py` splits each existing x block into two contiguous 16-atom halves. A y atom
survives for a half when at least one valid x atom is within the chosen radius. Receivers
compact across all ordinary tiles for the same x half. Each resulting list rounds up
to a full 32-receiver packet. No x state or mask interpreter is modeled.

- `padded.q` uses 1.08 times the cutoff, the existing construction radius.
- `cutoff.q` uses the force cutoff. It is an optimistic fresh-list pruning lower bound.
- `q_without_packet_padding` omits unused tail slots. It is not the executable format.
- `q_without_cross_tile_compaction` only repacks within each existing tile.
- `y_flush_ratio` is the number of full y packet flushes divided by old tile count, or 2q.
- Exceptional/diagonal tiles and single pairs are counted separately and unchanged.
  q compares ordinary list slots only. Unchanged work cannot improve that ratio.

The emulator uses float64 arithmetic on the downloaded float32 direct-force coordinates,
with reduced-box minimum images in z, y, x order. A few pairs at a floating-point cutoff
boundary can differ from MSL. The measured distance from the 0.75 threshold must be large
enough to make this immaterial. A surviving design still needs GPU list coverage tests.
Pruning a buffered list at its later coordinates does not establish a reusable list lifetime.

The pre-registered first kill is q > 0.75 on apoa1rf. No candidate GPU kernel may be
implemented before it passes. Later requirements are at least 15 percent fewer total
dynamic force instructions, at least 10 percent less force plus added list time, no
register/occupancy failure, then at least 3 percent host gain with no loss over 1 percent.

Reproduce outside 00:00 to 07:00 UTC:

```sh
/tmp/openmm-metal-bench/ultra-tools/sync.sh ~/code/wt/r3-nb16 /tmp/openmm-metal-bench/ultra-r3-nb16
/tmp/openmm-metal-bench/ultra-tools/bg.sh /tmp/openmm-metal-bench/ultra-r3-nb16/build.out /tmp/openmm-metal-bench/ultra-tools/build.sh /tmp/openmm-metal-bench/ultra-r3-nb16
# After the build completes, from this directory:
/tmp/openmm-metal-bench/ultra-tools/bg.sh "$PWD/capture.log" /bin/sh "$PWD/capture.sh"
# After capture completes:
/tmp/openmm-metal-bench/env/bin/python emulate.py snapshots/*.npz > q.jsonl
```

`capture.sh` compiles the bridge before entering one correctness lease. It checks quiet
hours again after acquiring the ticket. The experiment's native build and bridge compile check
C++ types; Python sources also receive a syntax check. The targeted CPU spec covers skew
periodic boxes and partial blocks against explicit image enumeration, compaction across
tile boundaries, and skin plus packet-padding costs.

## Force-loop diagnostic

`emit.py` materializes the padded-radius lists and sorts each x half's receivers by
atom index. Canonical packet membership removes GPU list-construction order from
floating-point grouping. This CPU emitter is for fixed-coordinate replay only.

`replay.cpp` uploads the compact list into separate arrays. It clears the long force
buffer, dispatches either force kernel, commits, and downloads the fixed-point result.
`replay.py` captures a live snapshot from the same context, emits its compact list,
compares direct forces with the current 32x32 kernel, then checks bitwise repetition.
It records coordinate and compact-format hashes for paired captures. The reported
force differences exclude bonded and reciprocal forces because the replay calls only
the direct nonbonded utility. Both kernels retain exceptional and single-pair work.

`counters.py` runs each path on those fixed coordinates and captures twelve command
buffers with gpucapture. It must run inside a timing lease. It records only its own
runner pid and terminates that runner after capture. `gdtarget.py`, copied from the
infra M0 tooling, profiles the capture and dumps the relevant shader, dispatch and
encoder counters. `readout.py` compares total dynamic instructions and force time.
The force-only time is an optimistic bound: GPU format emission is not included.
A surviving force loop still needs the independent emitter and the complete gate.
Fresh profiling can leave the performance tree empty. `gdtarget.py` now reopens
the trace and loads the embedded profile before reading counters. For these saved
captures, `rewalk.py` loaded both embedded profiles without GPU replay, as confirmed
by the reviewer. It preserved the initial empty walks as `target-empty.jsonl`.
After each session, the profiler removes only that trace's raw stream from
`/private/tmp/com.apple.gputools.profiling`. Cleanup also runs on SIGTERM.

Build the bridge with `build-replay.sh` after the candidate native build. Run a force
comparison with the assigned tree's Python, `replay.py --tree <tree> --bench <bench>`
under a correctness lease. Run `counters.py` under a timing lease. No timing windows
are used. The helper passes an explicit alternate template and list arguments; it
adds no environment selection to production and does not touch list-builder control.

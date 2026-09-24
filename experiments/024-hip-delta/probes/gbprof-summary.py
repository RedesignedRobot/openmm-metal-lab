"""Summarize GpuProf.h records.

usage: python gbprof-summary.py <steps> <records file>
Kernel records (GPUPROF=kernels): per kernel, dispatches per step, GPU us per step, and the
median, min and max of one dispatch, all from GPUEndTime - GPUStartTime of a buffer holding
only that dispatch. Buffer records (GPUPROF=buffers): buffers per step, GPU busy us per step,
the span from the first buffer's start to the last buffer's end, and host waits per step.
"""
import collections
import statistics
import sys

steps = int(sys.argv[1])
kernels = collections.defaultdict(list)
shapes = {}
buffers = []
waits = collections.defaultdict(list)
for line in open(sys.argv[2]):
    f = line.split()
    if f[0] == "k":
        kernels[f[1]].append(float(f[4])*1e6)
        shapes[f[1]] = f"{f[2]}x{f[3]}"
    elif f[0] == "b":
        buffers.append((float(f[1]), float(f[2]), float(f[3])) if len(f) > 3 else (float(f[1]), float(f[2])))
    elif f[0] == "w":
        waits[f[1]].append(float(f[2])*1e6)

if kernels:
    total = sum(sum(v) for v in kernels.values())
    print(f"| Kernel | Grid x threadgroup | Dispatches/step | GPU us/step | Median us | Min us | Max us |")
    print("|---|---|---:|---:|---:|---:|---:|")
    for name, times in sorted(kernels.items(), key=lambda kv: -sum(kv[1])):
        print(f"| {name} | {shapes[name]} | {len(times)/steps:.2f} | {sum(times)/steps:.2f} | "
              f"{statistics.median(times):.2f} | {min(times):.2f} | {max(times):.2f} |")
    print(f"| total | | {sum(len(v) for v in kernels.values())/steps:.2f} | {total/steps:.2f} | | | |")
if buffers:
    buffers.sort()
    busy, covered = 0.0, buffers[0][0]
    for start, end, *_ in buffers:
        if end > covered:
            busy += end-max(start, covered)
            covered = end
    span = buffers[-1][1]-buffers[0][0]
    print(f"buffers/step {len(buffers)/steps:.2f}  GPU busy us/step {busy/steps*1e6:.2f}  "
          f"span us/step {span/steps*1e6:.2f}  busy/span {busy/span:.3f}")
    if len(buffers[0]) > 2:
        # Idle time between buffers, split into the host committing after the GPU ran dry and the
        # delay from max(commit, previous end) to the buffer's GPU start.
        late, launch = 0.0, []
        for (_, prevEnd, _), (start, end, commit) in zip(buffers, buffers[1:]):
            if start <= prevEnd:
                continue
            late += max(0.0, commit-prevEnd)
            launch.append(start-max(commit, prevEnd))
        print(f"idle us/step: host committed after the GPU ran dry {late/steps*1e6:.2f}, commit or previous end to start "
              f"{sum(launch)/steps*1e6:.2f} (median {statistics.median(launch)*1e6:.2f} us)")
        lengths = [(end-start)*1e6 for start, end, _ in buffers]
        print(f"buffer GPU us, median of alternate buffers: {statistics.median(lengths[0::2]):.2f} and {statistics.median(lengths[1::2]):.2f}")
        ends = sorted(end for _, end, _ in buffers)
        import bisect
        wake = []
        for line in open(sys.argv[2]):
            f = line.split()
            if f[0] == "w" and f[1] == "event":
                waitEnd = float(f[3])+float(f[2])
                i = bisect.bisect_right(ends, waitEnd)-1
                if i >= 0:
                    wake.append((waitEnd-ends[i])*1e6)
        if wake:
            print(f"event wait end minus the last GPU end before it: median {statistics.median(wake):.2f} us")
for what, times in sorted(waits.items()):
    print(f"host wait {what}: {len(times)/steps:.2f}/step, {sum(times)/steps:.2f} us/step, median {statistics.median(times):.2f} us")

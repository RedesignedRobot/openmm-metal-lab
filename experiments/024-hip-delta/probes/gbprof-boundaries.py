"""Idle time before each command buffer, grouped by the boundary it follows.

usage: python gbprof-boundaries.py <steps> <records file>
Reads GpuProf.h "b" records (GPU start, GPU end, host commit, first kernel, last kernel). For each
buffer, the gap is its GPU start minus max(host commit, the previous buffer's GPU end), on the GPU
timestamps (mach_absolute_time base). Groups by "previous last kernel -> this first kernel".
"""
import collections
import statistics
import sys

steps = int(sys.argv[1])
buffers = []
for line in open(sys.argv[2]):
    f = line.split()
    if f[0] == "b" and len(f) >= 6:
        buffers.append((float(f[1]), float(f[2]), float(f[3]), f[4], f[5]))
buffers.sort()
groups = collections.defaultdict(list)
late = collections.defaultdict(float)
lengths = collections.defaultdict(list)
for prev, cur in zip(buffers, buffers[1:]):
    key = f"{prev[4]} -> {cur[3]}"
    groups[key].append((cur[0]-max(cur[2], prev[1]))*1e6)
    late[key] += max(0.0, cur[2]-prev[1])*1e6
for b in buffers:
    lengths[f"{b[3]}..{b[4]}"].append((b[1]-b[0])*1e6)
span = (buffers[-1][1]-buffers[0][0])/steps*1e6
print(f"buffers/step {len(buffers)/steps:.2f}  span us/step {span:.2f}")
print("| Boundary | Per step | Gap us/step | Median gap us | p90 us | Host late us/step |")
print("|---|---:|---:|---:|---:|---:|")
for key, gaps in sorted(groups.items(), key=lambda kv: -sum(kv[1])):
    gaps.sort()
    print(f"| {key} | {len(gaps)/steps:.2f} | {sum(gaps)/steps:.2f} | {statistics.median(gaps):.2f} | "
          f"{gaps[int(0.9*(len(gaps)-1))]:.2f} | {late[key]/steps:.2f} |")
print("| Buffer | Per step | Median GPU us |")
print("|---|---:|---:|")
for key, times in sorted(lengths.items(), key=lambda kv: -len(kv[1])):
    print(f"| {key} | {len(times)/steps:.2f} | {statistics.median(times):.2f} |")

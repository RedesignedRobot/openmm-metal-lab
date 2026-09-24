"""Union and sum of the encoders from one kernel to another, per step, from a counters-mode record.

usage: python segment.py <counters .rec or .rec.gz> [first kernel] [last kernel]
Defaults to integrateLangevinMiddlePart1 through integrateLangevinMiddlePart3, inclusive: everything a fused
LangevinMiddle kernel would replace. Encoders are taken in record order, which is encoding order within a
command buffer and completion order across buffers (one serial queue). Counter ticks are nanoseconds.
"""
import collections
import gzip
import statistics
import sys

path = sys.argv[1]
first = sys.argv[2] if len(sys.argv) > 2 else "integrateLangevinMiddlePart1"
last = sys.argv[3] if len(sys.argv) > 3 else "integrateLangevinMiddlePart3"
segments, current = [], None
for line in (gzip.open(path, "rt") if path.endswith(".gz") else open(path)):
    f = line.split()
    if f[0] != "e":
        continue
    name, t0, t1 = f[1], int(f[4]), int(f[5])
    if name == first:
        current = []
    if current is None:
        continue
    current.append((name, t0, t1))
    if name == last:
        segments.append(current)
        current = None

def union(intervals):
    total, covered = 0, None
    for start, end in sorted(intervals):
        if covered is None or start > covered:
            total += end-start
            covered = end
        elif end > covered:
            total += end-covered
            covered = end
    return total

unions = [union([(t0, t1) for _, t0, t1 in s])*1e-3 for s in segments]
sums = [sum(t1-t0 for _, t0, t1 in s)*1e-3 for s in segments]
spans = [(s[-1][2]-s[0][1])*1e-3 for s in segments]
shapes = collections.Counter(" ".join(n for n, _, _ in s) for s in segments)
per = collections.defaultdict(list)
for s in segments:
    for name, t0, t1 in s:
        per[name].append((t1-t0)*1e-3)
print(f"{path}: {len(segments)} segments {first} .. {last}")
print(f"union median {statistics.median(unions):.1f} us, mean {statistics.mean(unions):.1f}; "
      f"sum median {statistics.median(sums):.1f}, mean {statistics.mean(sums):.1f}; "
      f"span (first start to last end) median {statistics.median(spans):.1f}, mean {statistics.mean(spans):.1f}")
print(f"most common sequence ({shapes.most_common(1)[0][1]} of {len(segments)}): {shapes.most_common(1)[0][0]}")
for name, times in sorted(per.items(), key=lambda kv: -sum(kv[1])):
    print(f"  {name:36s} n/segment {len(times)/len(segments):.2f}  median {statistics.median(times):7.1f} us")

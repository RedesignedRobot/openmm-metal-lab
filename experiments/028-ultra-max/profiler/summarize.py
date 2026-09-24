"""Summarize one prof.py run: per-step host time, GPU busy time, idle gap, buffers, dispatches, waits,
and, from counters-mode records, GPU time per kernel.

usage: python summarize.py <prof.py output> <records file> [top N kernels]
Prints a readable report and a final "json {...}" line for aggregation. Step time is window B's
host clock; GPU times come from command buffer GPUStartTime/GPUEndTime and, per kernel, from
stage-boundary timestamp samples. On the M3 Ultra (macOS 27) the samples, both halves of a sampleTimestamps
pair and GPUStartTime*1e9 are all nanoseconds on one clock, so the sampleTimestamps slope is only a check.
"""
import collections
import gzip
import json
import statistics
import sys

windows = {}
for line in open(sys.argv[1]):
    f = line.split()
    if f and f[0] == "window":
        windows[f[1]] = {"steps": int(f[f.index("steps")+1]), "us": float(f[f.index("us_per_step")+1]),
                         "ns_day": float(f[f.index("ns_per_day")+1]), "cpu": float(f[f.index("cpu_per_host")+1])}
top = int(sys.argv[3]) if len(sys.argv) > 3 else 10
steps = windows["B"]["steps"]
numer, denom = 1, 1
calib, buffers, encoders, kernels = [], [], [], collections.defaultdict(list)
waits = collections.defaultdict(list)
notes = []
for line in (gzip.open(sys.argv[2], "rt") if sys.argv[2].endswith(".gz") else open(sys.argv[2])):
    f = line.split()
    if f[0] == "t":
        numer, denom = int(f[1]), int(f[2])
    elif f[0] == "c":
        calib.append((int(f[1]), int(f[2])))
    elif f[0] == "b":
        buffers.append({"start": float(f[1]), "end": float(f[2]), "commit": float(f[3]), "dispatches": int(f[7]), "blits": int(f[8])})
    elif f[0] == "e":
        encoders.append((f"{f[1]} {f[2]}x{f[3]}", int(f[4]), int(f[5])))
    elif f[0] == "k":
        kernels[f"{f[1]} {f[2]}x{f[3]}"].append(float(f[4]))
    elif f[0] == "w":
        waits[f[1]].append(float(f[2]))
    elif f[0] == "x":
        notes.append(line.strip())

out = {"steps": steps, "wall_us": windows["B"]["us"], "unprofiled_us": [windows["A"]["us"], windows["C"]["us"]],
       "ns_day_unprofiled": statistics.mean([windows["A"]["ns_day"], windows["C"]["ns_day"]]), "cpu_cores": windows["B"]["cpu"]}
print(f"windows us/step: A {windows['A']['us']:.2f}  B (recorded) {windows['B']['us']:.2f}  C {windows['C']['us']:.2f}  "
      f"B/mean(A,C) {windows['B']['us']/statistics.mean([windows['A']['us'], windows['C']['us']]):.3f}")
for n in notes:
    print(n)

def union(intervals):
    total, covered = 0.0, None
    for start, end in sorted(intervals):
        if covered is None or start > covered:
            total += end-start
            covered = end
        elif end > covered:
            total += end-covered
            covered = end
    return total

# Encoders overlap when Metal runs consecutive ones concurrently, so a kernel's own start-to-end time counts time
# it shared. This splits every stretch of covered time evenly among the encoders running in it; the shares add
# up to the union.
def shares(intervals):
    events = sorted([(s, 1, i) for i, (s, e) in enumerate(intervals)] + [(e, 0, i) for i, (s, e) in enumerate(intervals)])
    share, active, previous = [0.0]*len(intervals), set(), None
    for t, starting, i in events:
        if active:
            for j in active:
                share[j] += (t-previous)/len(active)
        previous = t
        if starting:
            active.add(i)
        else:
            active.discard(i)
    return share

# A kernel with a slow path (findBlocksWithInteractions rebuilding the list) has two clusters of durations. Overlap
# stretches the fast ones past any fixed multiple of the minimum, so this splits at the largest ratio between
# neighbouring sorted durations and returns the slow cluster's share and that ratio. Each cluster must hold 1% of the
# dispatches, so a single cold first dispatch doesn't become the split, and the ratio must reach 2x, or the kernel
# counts as having one cluster (share 0). findBlocksWithInteractions gaps measured 4x to 57x, computeNonbonded 1.0x.
MIN_CLUSTER = 0.01
MIN_GAP = 2.0
def slow_mode(times):
    ordered = sorted(t for t in times if t > 0)
    edge = max(1, int(len(ordered)*MIN_CLUSTER))
    if len(ordered) < 2*edge+1:
        return 0.0, 1.0
    ratio, cut = max((ordered[i+1]/ordered[i], ordered[i]) for i in range(edge-1, len(ordered)-edge))
    if ratio < MIN_GAP:
        return 0.0, ratio
    return sum(t > cut for t in ordered)/len(times), ratio

if buffers:
    buffers.sort(key=lambda b: b["start"])
    busy = union([(b["start"], b["end"]) for b in buffers])
    late = sum(max(0.0, b["commit"]-p["end"]) for p, b in zip(buffers, buffers[1:]) if b["start"] > p["end"])
    out.update({"busy_us": busy/steps*1e6, "gap_us": windows["B"]["us"]-busy/steps*1e6, "buffers": len(buffers)/steps,
                "dispatches": sum(b["dispatches"] for b in buffers)/steps, "blits": sum(b["blits"] for b in buffers)/steps,
                "late_commit_us": late/steps*1e6})
    print(f"per step: wall {out['wall_us']:.2f} us, GPU busy {out['busy_us']:.2f} us, idle gap {out['gap_us']:.2f} us "
          f"(of which the host committed after the GPU ran dry {out['late_commit_us']:.2f} us), buffers {out['buffers']:.2f}, "
          f"dispatches {out['dispatches']:.2f}, blits {out['blits']:.2f}")
for what, times in sorted(waits.items()):
    out[f"wait_{what}"] = len(times)/steps
    out[f"wait_{what}_us"] = sum(times)/steps*1e6
    print(f"host wait {what}: {len(times)/steps:.2f}/step, {sum(times)/steps*1e6:.2f} us/step, median {statistics.median(times)*1e6:.2f} us")

if encoders:
    if len(calib) >= 2:
        (c0, g0), (c1, g1) = calib[0], calib[-1]
        slope = (c1-c0)/(g1-g0)
    else:
        (c0, g0), slope = calib[0], 1.0
        print("one calibration pair: assuming GPU ticks are nanoseconds")
    seconds = lambda ticks: ticks*slope*1e-9
    per = collections.defaultdict(list)
    intervals, owners = [], []
    bad = 0
    for name, t0, t1 in encoders:
        if t0 in (0, 2**64-1) or t1 in (0, 2**64-1) or t1 < t0:
            bad += 1
            continue
        per[name].append(seconds(t1-t0))
        intervals.append((seconds(t0-g0), seconds(t1-g0)))
        owners.append(name)
    total = sum(sum(v) for v in per.values())
    covered = union(intervals)
    attributed = collections.defaultdict(float)
    for name, share in zip(owners, shares(intervals)):
        attributed[name] += share
    out.update({"kernel_sum_us": total/steps*1e6, "kernel_union_us": covered/steps*1e6, "bad_samples": bad,
                "tick_slope": slope, "kernels": {}})
    print(f"counter samples: {len(encoders)} encoders, {bad} invalid, GPU tick = {slope:.4f} ns; "
          f"sum of encoder times {total/steps*1e6:.2f} us/step, their union {covered/steps*1e6:.2f} us/step")
    print("| Kernel, grid x threadgroup | Per step | us/step | Attributed us/step | Attributed share | Median us | p10 us | p90 us | Slow mode (gap) |")
    print("|---|---:|---:|---:|---:|---:|---:|---:|---:|")
    ranked = sorted(per.items(), key=lambda kv: -attributed[kv[0]])
    for name, times in ranked:
        q = statistics.quantiles(times, n=10) if len(times) > 1 else times*9
        out["kernels"][name] = {"n": len(times)/steps, "us": sum(times)/steps*1e6, "attr": attributed[name]/steps*1e6,
                                "median": statistics.median(times)*1e6, "p10": q[0]*1e6, "p90": q[-1]*1e6,
                                "slow": slow_mode(times)}
    for name, times in ranked[:top]:
        k = out["kernels"][name]
        print(f"| {name} | {k['n']:.2f} | {k['us']:.2f} | {k['attr']:.2f} | {attributed[name]/covered:.1%} | {k['median']:.2f} | "
              f"{k['p10']:.2f} | {k['p90']:.2f} | {k['slow'][0]:.0%} ({k['slow'][1]:.1f}x) |")
    rest = ranked[top:]
    if rest:
        print(f"| {len(rest)} others | {sum(len(v) for _, v in rest)/steps:.2f} | {sum(sum(v) for _, v in rest)/steps*1e6:.2f} | "
              f"{sum(attributed[k] for k, _ in rest)/steps*1e6:.2f} | {sum(attributed[k] for k, _ in rest)/covered:.1%} | |")
if kernels:
    total = sum(sum(v) for v in kernels.values())
    out["kernels_isolated"] = {k: sum(v)/steps*1e6 for k, v in kernels.items()}
    print(f"isolated kernels: {total/steps*1e6:.2f} us/step")
    for name, times in sorted(kernels.items(), key=lambda kv: -sum(kv[1]))[:top]:
        print(f"| {name} | {len(times)/steps:.2f} | {sum(times)/steps*1e6:.2f} | {sum(times)/total:.1%} | {statistics.median(times)*1e6:.2f} |")
print("json " + json.dumps(out))

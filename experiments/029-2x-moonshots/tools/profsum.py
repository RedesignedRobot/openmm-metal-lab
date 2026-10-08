"""Per-kernel GPU time per step for one gpuprof.sh target, from its buffers, split and counters runs.

usage: python3 profsum.py <outdir> <tag> [top N kernels]
Reads <outdir>/<tag>-<mode>.txt (prof.py's windows) and <tag>-<mode>.rec[.gz] (GpuProf.h records) for each mode
that ran, prints a report, and ends with one "json {...}" line.

Clocks: step time is prof.py's window B on the host clock (time.perf_counter). GPU busy is the union of command
buffer GPUStartTime..GPUEndTime. Idle is window B minus busy. Kernel times come from stage-boundary timestamp samples,
one encoder per dispatch; on the M3 Ultra (macOS 27) they are nanoseconds on the same clock as GPUStartTime*1e9,
so the sampleTimestamps slope is only a check.

Indirect dispatches (the list build: countBlockBins, sumBlockBins, scatterBlocks, sortBoxData,
findBlocksWithInteractions) often write no stage-boundary samples on the M3 Ultra: always when the GPU skips them
(zero threadgroups), and on some real rebuilds too. The sample slots then hold zeros or stale ticks from the sample
buffer's previous command buffer. A sample outside its own buffer's GPU window counts as unstamped, and the time
between the stamped encoders around a run of unstamped ones, in the same command buffer, goes to an "unstamped
<names>" row. Serial encoders in one buffer don't overlap, so that bracket holds only their work and their
boundaries. Measured on tip4pew mixed: 3.8 us for a skipped list build, 40-300 us for an unstamped rebuild.

Each mode's record cost is its window B over the mean of its unrecorded windows A and C, in one process. The split
price is split's ratio minus buffers' ratio: one encoder per dispatch, which also removes the overlap of concurrent
passes. The kernel table is attributed time: every stretch of covered GPU time is shared evenly among the encoders
running in it, so the rows add up to the union of encoder time.

Validation (counters run): the union of encoder time against window B minus idle, both from the counters run,
must agree within VALID_TOLERANCE. A second line compares it with the buffers run's busy time, the GPU time of the
undivided build, which shows how far the split moved the table.
"""
import collections
import gzip
import json
import os
import statistics
import sys

VALID_TOLERANCE = 0.10
WINDOW_SLACK_NS = 2000  # stamps sit 0.04 us inside their buffer's GPUStartTime..GPUEndTime
MODES = ("buffers", "split", "counters")


def read_windows(path):
    windows = {}
    for line in open(path):
        f = line.split()
        if f and f[0] == "window":
            windows[f[1]] = {"steps": int(f[f.index("steps")+1]), "us": float(f[f.index("us_per_step")+1]),
                             "cpu": float(f[f.index("cpu_per_host")+1])}
    return windows


def read_records(path):
    r = {"calib": [], "buffers": [], "encoders": [], "waits": collections.defaultdict(list), "notes": []}
    opener = gzip.open if path.endswith(".gz") else open
    for line in opener(path, "rt"):
        f = line.split()
        if not f:
            continue
        if f[0] == "c":
            r["calib"].append((int(f[1]), int(f[2])))
        elif f[0] == "b":
            r["buffers"].append((float(f[1]), float(f[2]), float(f[3]), int(f[7]), int(f[8]), int(f[9]), []))
        elif f[0] == "e":
            # GpuProf.h writes a buffer's encoders right after its "b" line, in encoding order.
            r["encoders"].append(1)
            r["buffers"][-1][6].append((f"{f[1]} {f[2]}x{f[3]}", int(f[4]), int(f[5])))
        elif f[0] == "w":
            r["waits"][f[1]].append(float(f[2]))
        elif f[0] == "x":
            r["notes"].append(line.strip())
    return r


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


def shares(intervals):
    """Splits every stretch of covered time evenly among the intervals running in it; the shares add up to the union."""
    # Starts sort before ends at the same time, so a zero-length interval (a skipped list build's bracket) leaves again.
    events = sorted([(s, 0, i) for i, (s, e) in enumerate(intervals)] + [(e, 1, i) for i, (s, e) in enumerate(intervals)])
    share, active, previous = [0.0]*len(intervals), set(), None
    for t, ending, i in events:
        if active:
            for j in active:
                share[j] += (t-previous)/len(active)
        previous = t
        if ending:
            active.discard(i)
        else:
            active.add(i)
    return share


def buffer_stats(records, steps, wall_us):
    buffers = sorted(records["buffers"])
    if not buffers:
        return {}
    busy = union([(b[0], b[1]) for b in buffers])/steps*1e6
    out = {"wall_us": wall_us, "busy_us": busy, "idle_us": wall_us-busy, "buffers": len(buffers)/steps,
           "dispatches": sum(b[3] for b in buffers)/steps, "blits": sum(b[4] for b in buffers)/steps,
           "overflow": sum(b[5] for b in buffers)}
    for what, times in sorted(records["waits"].items()):
        out[f"wait_{what}_us"] = sum(times)/steps*1e6
        out[f"wait_{what}_n"] = len(times)/steps
    return out


def buffer_intervals(buffer):
    """(name, start ns, end ns) for the buffer's stamped encoders and its bracketed runs of unstamped ones."""
    start, end = buffer[0]*1e9, buffer[1]*1e9
    out, pending, previous = [], [], start
    for name, t0, t1 in buffer[6]:
        if not (start-WINDOW_SLACK_NS <= t0 <= t1 <= end+WINDOW_SLACK_NS):
            if name.split()[0] not in pending:
                pending.append(name.split()[0])
            continue
        if pending:
            out.append(("unstamped " + "+".join(pending), previous, max(previous, t0)))
            pending = []
        out.append((name, t0, t1))
        previous = t1
    if pending:
        out.append(("unstamped " + "+".join(pending), previous, max(previous, end)))
    return out


def kernel_table(records, steps):
    calib = records["calib"]
    slope = 1.0
    if len(calib) >= 2 and calib[-1][1] != calib[0][1]:
        slope = (calib[-1][0]-calib[0][0])/(calib[-1][1]-calib[0][1])
    per, intervals, owners, unstamped = collections.defaultdict(list), [], [], 0
    for buffer in records["buffers"]:
        for name, t0, t1 in buffer_intervals(buffer):
            unstamped += name.startswith("unstamped ")
            per[name].append((t1-t0)*1e-9)
            intervals.append((t0*1e-9, t1*1e-9))
            owners.append(name)
    attributed = collections.defaultdict(float)
    for name, share in zip(owners, shares(intervals)):
        attributed[name] += share
    kernels = {}
    for name, times in per.items():
        kernels[name] = {"n": len(times)/steps, "us": sum(times)/steps*1e6, "attr_us": attributed[name]/steps*1e6,
                         "median_us": statistics.median(times)*1e6}
    return {"encoders": len(records["encoders"]), "unstamped_runs": unstamped, "tick_slope": slope,
            "kernel_sum_us": sum(sum(v) for v in per.values())/steps*1e6,
            "kernel_union_us": union(intervals)/steps*1e6, "kernels": kernels}


def summarize(outdir, tag, top):
    report = {"tag": tag}
    for mode in MODES:
        txt = os.path.join(outdir, f"{tag}-{mode}.txt")
        rec = next((p for p in (os.path.join(outdir, f"{tag}-{mode}.rec"), os.path.join(outdir, f"{tag}-{mode}.rec.gz"))
                    if os.path.exists(p)), None)
        if not os.path.exists(txt) or rec is None:
            continue
        windows = read_windows(txt)
        if set(windows) != set("ABC"):
            report[mode] = {"error": f"{txt} has windows {sorted(windows)}"}
            continue
        steps = windows["B"]["steps"]
        base = statistics.mean([windows["A"]["us"], windows["C"]["us"]])
        records = read_records(rec)
        m = {"steps": steps, "us_A": windows["A"]["us"], "us_B": windows["B"]["us"], "us_C": windows["C"]["us"],
             "record_ratio": windows["B"]["us"]/base, "notes": records["notes"]}
        m.update(buffer_stats(records, steps, windows["B"]["us"]))
        if records["encoders"]:
            m.update(kernel_table(records, steps))
        report[mode] = m
    buffers, split, counters = (report.get(m, {}) for m in MODES)
    if "record_ratio" in buffers and "record_ratio" in split:
        report["split_price"] = split["record_ratio"]-buffers["record_ratio"]
        report["split_price_us"] = report["split_price"]*statistics.mean([buffers["us_A"], buffers["us_C"]])
    if "kernel_union_us" in counters and "busy_us" in counters:
        busy = counters["wall_us"]-counters["idle_us"]
        report["valid_err"] = counters["kernel_union_us"]/busy-1
        report["valid"] = abs(report["valid_err"]) <= VALID_TOLERANCE and counters["overflow"] == 0
        if "busy_us" in buffers:
            report["vs_buffers_busy"] = counters["kernel_union_us"]/buffers["busy_us"]-1
    print_report(report, top)
    return report


def print_report(r, top):
    print(f"== {r['tag']}")
    for mode in MODES:
        m = r.get(mode)
        if m is None:
            print(f"{mode}: missing")
            continue
        if "error" in m:
            print(f"{mode}: {m['error']}")
            continue
        line = (f"{mode}: us/step A {m['us_A']:.2f} B {m['us_B']:.2f} C {m['us_C']:.2f}, B/mean(A,C) {m['record_ratio']:.3f}")
        if "busy_us" in m:
            line += (f"; GPU busy {m['busy_us']:.2f}, idle {m['idle_us']:.2f}, buffers {m['buffers']:.2f}, "
                     f"dispatches {m['dispatches']:.2f}, blits {m['blits']:.2f} per step")
        print(line)
        waits = ", ".join(f"{k[5:-3]} {v:.2f} us ({m[k[:-3]+'_n']:.2f}/step)" for k, v in m.items() if k.startswith("wait_") and k.endswith("_us"))
        if waits:
            print(f"  host waits: {waits}")
        for note in m["notes"]:
            print(f"  {note}")
    if "split_price" in r:
        print(f"split price: {r['split_price']:+.3f} of step time, {r['split_price_us']:+.2f} us/step "
              "(split's B/mean(A,C) minus buffers')")
    c = r.get("counters", {})
    if "kernels" not in c:
        return
    print(f"counters: {c['encoders']} encoders, {c['unstamped_runs']} runs of unstamped ones bracketed, {c['overflow']} overflowed, "
          f"sampleTimestamps slope {c['tick_slope']:.4f}; "
          f"encoder sum {c['kernel_sum_us']:.2f} us/step, union {c['kernel_union_us']:.2f} us/step")
    if "valid_err" in r:
        print(f"validation: union {c['kernel_union_us']:.2f} against window B minus idle {c['wall_us']-c['idle_us']:.2f} us/step, "
              f"{r['valid_err']:+.1%}: {'PASS' if r['valid'] else 'FAIL'} (tolerance {VALID_TOLERANCE:.0%})")
    if "vs_buffers_busy" in r:
        print(f"against the buffers run's GPU busy {r['buffers']['busy_us']:.2f} us/step: {r['vs_buffers_busy']:+.1%}")
    ranked = sorted(c["kernels"].items(), key=lambda kv: -kv[1]["attr_us"])
    union_us = c["kernel_union_us"]
    print("| Kernel, grid x threadgroup | Per step | Attributed us/step | Share | Own us/step | Median us |")
    print("|---|---:|---:|---:|---:|---:|")
    for name, k in ranked[:top]:
        print(f"| {name} | {k['n']:.2f} | {k['attr_us']:.2f} | {k['attr_us']/union_us:.1%} | {k['us']:.2f} | {k['median_us']:.2f} |")
    rest = ranked[top:]
    if rest:
        attr = sum(k["attr_us"] for _, k in rest)
        print(f"| {len(rest)} others | {sum(k['n'] for _, k in rest):.2f} | {attr:.2f} | {attr/union_us:.1%} | "
              f"{sum(k['us'] for _, k in rest):.2f} | |")


if __name__ == "__main__":
    report = summarize(sys.argv[1], sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 15)
    print("json " + json.dumps(report))

"""Group the GPU idle between command buffers by cause, from a GpuProf buffers-mode record (r3-fah).

usage: python3 idlegaps.py <tag>.rec <tag>.txt [min_gap_us, default 20]

The record comes from ultra-tools/prof.py with GPUPROF=buffers (window B only). Each "b" line is one command
buffer: GPU start, GPU end, host commit time, first and last kernel, scheduled time, dispatches, blits. Each "w"
line is a host wait: label, seconds, start, then the caller's backtrace addresses when the tree carries r3-fah's
instrument (scratch/instrument.py); "a" lines symbolize those addresses at exit.

A gap between consecutive buffers is charged to the host wait that spans it (labelled by the innermost
interesting caller in its backtrace), else to a late commit (the host committed after the GPU ran dry: host part
plus commit-to-start latency), else to the scheduler (committed in time, started late). Sums are per step, using
window B's step count from the .txt.
"""
import re
import statistics
import sys
from collections import defaultdict

INTERESTING = ("reduceEnergy", "computeKineticEnergy", "prefetchKineticEnergy", "syncHost", "uploadSubArray",
               "setPeriodicBoxVectors", "restoreCoordinates", "saveCoordinates", "scaleCoordinates",
               "applyConstraints", "waitForCountCopy", "computeInteractions", "download", "reorderAtoms",
               "updateContextState", "getState", "calcForcesAndEnergy", "calcKineticEnergy", "computeVirtualSites",
               "updateParametersInContext", "setPositions", "setVelocities", "getPositions", "getVelocities",
               "step", "finishComputation", "beginComputation")


def load(rec_path):
    buffers, waits, symbols = [], [], {}
    for line in open(rec_path):
        parts = line.split()
        if not parts:
            continue
        if parts[0] == "b":
            gstart, gend, committed = float(parts[1]), float(parts[2]), float(parts[3])
            first, last, scheduled = parts[4], parts[5], float(parts[6])
            buffers.append((gstart, gend, committed, first, last, scheduled, int(parts[7]), int(parts[8])))
        elif parts[0] == "w":
            waits.append((float(parts[3]), float(parts[2]), parts[1], parts[4:]))
        elif parts[0] == "a":
            symbols[parts[1]] = parts[4] if len(parts) > 4 else "?"
    buffers.sort()
    waits.sort()
    return buffers, waits, symbols


def site(frames, symbols):
    names = []
    for f in frames:
        s = symbols.get(f, "?")
        for token in INTERESTING:
            if token in s and (not names or names[-1] != token):
                names.append(token)
                break
        if len(names) == 3:
            break
    return "<".join(names) if names else "unknown"


def steps_of(txt_path):
    for line in open(txt_path):
        m = re.match(r"window B .* steps (\d+) host_s (\S+) us_per_step (\S+)", line)
        if m:
            return int(m.group(1)), float(m.group(3))
    raise SystemExit("no window B line in " + txt_path)


def main():
    rec, txt = sys.argv[1], sys.argv[2]
    min_gap = float(sys.argv[3]) * 1e-6 if len(sys.argv) > 3 else 20e-6
    buffers, waits, symbols = load(rec)
    steps, us_per_step = steps_of(txt)
    if len(buffers) < 2:
        raise SystemExit("too few buffers")
    span = buffers[-1][1] - buffers[0][0]
    busy = sum(b[1] - b[0] for b in buffers)
    causes = defaultdict(list)
    small = 0.0
    wi = 0
    for i in range(len(buffers) - 1):
        prev, nxt = buffers[i], buffers[i + 1]
        gap = nxt[0] - prev[1]
        if gap <= 0:
            continue
        if gap < min_gap:
            small += gap
            continue
        while wi < len(waits) and waits[wi][0] + waits[wi][1] < prev[1]:
            wi += 1
        spanning = None
        for w in waits[wi:]:
            if w[0] > nxt[0]:
                break
            if w[0] + w[1] >= prev[1]:
                spanning = w
                break
        if spanning is not None:
            label = f"wait {spanning[2]} [{site(spanning[3], symbols)}]"
            wake = spanning[0] + spanning[1]
            detail = (prev[4], nxt[3], wake - prev[1], nxt[2] - wake, nxt[0] - nxt[2])
        elif nxt[2] > prev[1]:
            label = "late commit"
            detail = (prev[4], nxt[3], nxt[2] - prev[1], nxt[0] - nxt[2])
        else:
            label = "scheduler gap"
            detail = (prev[4], nxt[3])
        causes[label].append((gap, detail))
    idle = span - busy
    print(f"{rec}: {len(buffers)} buffers, {steps} steps, window B {us_per_step:.1f} us/step, span {span/steps*1e6:.1f}, "
          f"busy {busy/steps*1e6:.1f}, idle {idle/steps*1e6:.1f} us/step; gaps under {min_gap*1e6:.0f} us: {small/steps*1e6:.1f} us/step")
    print("| cause | per step | us/step | median us | kernels around (most common) | extra |")
    print("|---|---:|---:|---:|---|---|")
    for label, gaps in sorted(causes.items(), key=lambda kv: -sum(g for g, _ in kv[1])):
        total = sum(g for g, _ in gaps)
        pairs = defaultdict(int)
        for _, d in gaps:
            pairs[(d[0], d[1])] += 1
        common = max(pairs.items(), key=lambda kv: kv[1])
        extra = ""
        if label == "late commit":
            host = statistics.median(d[2] for _, d in gaps) * 1e6
            lat = statistics.median(d[3] for _, d in gaps) * 1e6
            extra = f"host after GPU end med {host:.0f} us, commit to start med {lat:.0f} us"
        elif label.startswith("wait"):
            wake = statistics.median(d[2] for _, d in gaps) * 1e6
            encode = statistics.median(d[3] for _, d in gaps) * 1e6
            lat = statistics.median(d[4] for _, d in gaps) * 1e6
            extra = f"GPU end to wait return med {wake:.0f} us, then to commit med {encode:.0f} us, commit to start med {lat:.0f} us"
        print(f"| {label} | {len(gaps)/steps:.3f} | {total/steps*1e6:.1f} | {statistics.median(g for g, _ in gaps)*1e6:.0f} | "
              f"{common[0][0]} -> {common[0][1]} ({common[1]} of {len(gaps)}) | {extra} |")
    by_label = defaultdict(list)
    for w in waits:
        by_label[f"{w[2]} [{site(w[3], symbols)}]"].append(w[1])
    print("host waits (all, window B):")
    for label, v in sorted(by_label.items(), key=lambda kv: -sum(kv[1])):
        print(f"  {label}: {len(v)/steps:.3f}/step, {sum(v)/steps*1e6:.1f} us/step, median {statistics.median(v)*1e6:.0f} us")


if __name__ == "__main__":
    main()

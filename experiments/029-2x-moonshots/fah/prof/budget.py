"""Per-step GPU budget of one work-unit shader timeline (r3-fah), from tracewu.sh's intervals export.

usage: budget.py <trace dir> <tag> <anchor kernel> [anchors per step, default 1]
       budget.py <trace dir> <tag> --window

--window budgets profwu.py's timed window instead: the last `seconds` of the trace (it ends at the final getState),
over the `steps` the host timed. It needs no anchor and survives dropped rows, because each kernel's sampled time is
divided by a step count the host knows. Calls per step there count sampled rows, not dispatches. Use it where step
mode keeps too few steps; it matches step mode within a few us/step on the complete traces.

Rows are filtered by the pid profwu.py wrote to <tag>.pypid. The anchor is a kernel that runs once per step (the
integrator's), or a kernel that runs a fixed number of times per step (computeNonbonded runs twice per neq step: Eold
and Enew); the trace splits into steps at every such start. The sampled shader profiler drops whole command buffers
(one hole per step on some Metal traces), so only complete steps count: a step is kept when it holds every core kernel
(one present in at least 80% of steps) and runs no longer than 4x the median step. Busy is the union of intervals
inside kept steps, so overlapping kernels count once; idle is the kept steps' length minus busy. Per-kernel numbers
are summed durations and calls per kept step; summed durations can exceed busy when kernels overlap, and an
overlapped kernel's duration includes the time it shared the GPU. Occasional kernels (random numbers, list rebuilds,
the barostat's trial energy) are averaged over the kept steps that hold them, so a dropped occasional kernel reads low.
Apple's OpenCL traces of small systems record about 15 dispatches per kernel; there only the per-call column holds.
"""
import collections
import json
import sys
import xml.etree.ElementTree as ET


def rows_of(path, pid):
    texts, rows = {}, []

    def value(x):
        if x.get("ref"):
            return texts.get(x.get("ref"))
        return x.text if x.tag in ("start-time", "duration") else x.get("fmt") or x.text or ""

    for _, e in ET.iterparse(path, events=("end",)):
        if e.get("id") is not None:
            texts[e.get("id")] = e.text if e.tag in ("start-time", "duration") else (e.get("fmt") or e.text or "")
        if e.tag == "row":
            c = list(e)
            if f"({pid})" in value(c[11]):
                name = value(c[2]).rsplit(" (", 1)[0].removeprefix("__entry_")
                rows.append((int(value(c[0])), int(value(c[1])), name))
            e.clear()
    rows.sort()
    return rows


def window(trace, tag):
    pid = open(f"{trace}/{tag}.pypid").read().strip()
    rows = rows_of(f"{trace}/{tag}-intervals.xml", pid)
    host = json.loads(open(f"{trace}/{tag}.txt").read().strip().splitlines()[-1])
    t1 = max(s + d for s, d, _ in rows)
    t0 = t1 - host["seconds"] * 1e9
    kern, count = collections.defaultdict(float), collections.Counter()
    busy, end = 0, t0
    for s, d, n in rows:
        if s + d <= t0:
            continue
        s = max(s, t0)
        kern[n] += min(s + d, t1) - s
        count[n] += 1
        e = min(s + d, t1)
        if e > end:
            busy += e - max(s, end)
            end = e
    m = host["steps"]
    print(f"{tag}: host {host['us_per_step']} us/step ({host['platform']} {host['precision']} {host['variant']}, "
          f"{host['atoms']} atoms); timed window {host['seconds']} s, {m} steps")
    print(f"  busy {busy/m/1e3:.1f}  idle {host['us_per_step'] - busy/m/1e3:.1f} us/step, {sum(count.values())/m:.1f} rows/step")
    print(f"  {'kernel':34s} {'us/step':>8s} {'rows/step':>10s}")
    for n in sorted(kern, key=lambda n: -kern[n]):
        print(f"  {n:34s} {kern[n]/m/1e3:8.1f} {count[n]/m:10.3f}")


def main():
    if sys.argv[3] == "--window":
        window(sys.argv[1], sys.argv[2])
        return
    trace, tag, anchor = sys.argv[1], sys.argv[2], sys.argv[3]
    per = int(sys.argv[4]) if len(sys.argv) > 4 else 1
    pid = open(f"{trace}/{tag}.pypid").read().strip()
    rows = rows_of(f"{trace}/{tag}-intervals.xml", pid)
    host = json.loads(open(f"{trace}/{tag}.txt").read().strip().splitlines()[-1])
    marks = [s for s, _, n in rows if n == anchor][::per]
    steps = [[] for _ in marks[:-1]]
    i = 0
    for s, d, n in rows:
        while i < len(marks) - 1 and s >= marks[i + 1]:
            i += 1
        if marks[0] <= s < marks[-1]:
            steps[i].append((s, d, n))
    present = collections.Counter(n for step in steps for n in {n for _, _, n in step})
    core = {n for n, c in present.items() if c >= 0.8 * len(steps)}
    length = [marks[k + 1] - marks[k] for k in range(len(steps))]
    typical = sorted(length)[len(length) // 2]
    kept = [k for k, step in enumerate(steps) if core <= {n for _, _, n in step} and length[k] <= 4 * typical]
    kern, count = collections.defaultdict(float), collections.Counter()
    busy = wall = 0
    for k in kept:
        end = marks[k]
        for s, d, n in steps[k]:
            kern[n] += d
            count[n] += 1
            e = min(s + d, marks[k + 1])
            if e > end:
                busy += e - max(s, end)
                end = e
        wall += length[k]
    m = len(kept)
    print(f"{tag}: host {host['us_per_step']} us/step ({host['platform']} {host['precision']} {host['variant']}, "
          f"{host['atoms']} atoms); {m} of {len(steps)} traced steps complete (every core kernel present), "
          f"{wall/m/1e3:.1f} us/step between {anchor} starts")
    print(f"  busy {busy/m/1e3:.1f}  idle {(wall - busy)/m/1e3:.1f} us/step, {sum(count.values())/m:.1f} dispatches/step")
    print(f"  {'kernel':34s} {'us/step':>8s} {'calls/step':>10s} {'us/call':>8s}")
    for n in sorted(kern, key=lambda n: -kern[n]):
        print(f"  {n:34s} {kern[n]/m/1e3:8.1f} {count[n]/m:10.3f} {kern[n]/count[n]/1e3:8.2f}{'' if n in core else '  (not every step)'}")


if __name__ == "__main__":
    main()

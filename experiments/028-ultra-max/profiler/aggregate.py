"""Tables across tests from summarize.py's json lines.

usage: python aggregate.py steps <dir> <precision> <mode>        per-step table
       python aggregate.py top <dir> <precision> [N]              top N kernels per test (counters mode)
       python aggregate.py mixed <dir> [N]                       mixed over single, per kernel (counters mode)
Kernel times are summarize.py's attributed times: overlapping encoder time split evenly, adding up to GPU busy time.
"""
import glob
import json
import os
import sys

TESTS = ["gbsa", "rf", "pme", "apoa1rf", "apoa1pme", "apoa1ljpme", "amber20-dhfr", "amber20-cellulose", "amber20-stmv"]

def load(directory, test, precision, mode):
    path = os.path.join(directory, f"{test}-{precision}-{mode}.sum")
    if not os.path.exists(path):
        return None
    for line in open(path):
        if line.startswith("json "):
            return json.loads(line[5:])
    return None

def short(name):
    kernel, shape = name.rsplit(" ", 1)
    return f"{kernel} ({shape})"

what = sys.argv[1]
if what == "steps":
    directory, precision, mode = sys.argv[2:5]
    print("| Test | Wall us/step | GPU busy us/step | Idle gap us/step | Gap share | Buffers/step | Dispatches/step | Event waits/step | Finish waits/step | Recorded/unrecorded |")
    print("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    for test in TESTS:
        d = load(directory, test, precision, mode)
        if d is None or "busy_us" not in d:
            print(f"| {test} | no result | | | | | | | | |")
            continue
        base = sum(d["unprofiled_us"])/2
        print(f"| {test} | {d['wall_us']:.1f} | {d['busy_us']:.1f} | {d['gap_us']:.1f} | {d['gap_us']/d['wall_us']:.1%} | "
              f"{d['buffers']:.2f} | {d['dispatches']:.1f} | {d.get('wait_event', 0):.2f} | {d.get('wait_finish', 0):.3f} | {d['wall_us']/base:.3f} |")
elif what == "top":
    directory, precision = sys.argv[2:4]
    n = int(sys.argv[4]) if len(sys.argv) > 4 else 5
    for test in TESTS:
        d = load(directory, test, precision, "counters")
        if d is None or "kernels" not in d:
            print(f"{test}: no result")
            continue
        total = d["kernel_union_us"]
        ranked = sorted(d["kernels"].items(), key=lambda kv: -kv[1]["attr"])
        cells = "; ".join(f"{short(k)} {v['attr']:.1f} us {v['attr']/total:.0%}" for k, v in ranked[:n])
        print(f"| {test} | {total:.1f} | {cells} |")
elif what == "mixed":
    directory = sys.argv[2]
    n = int(sys.argv[3]) if len(sys.argv) > 3 else 6
    for test in TESTS:
        s, m = load(directory, test, "single", "counters"), load(directory, test, "mixed", "counters")
        if s is None or m is None:
            print(f"{test}: missing")
            continue
        byName = lambda d: {k.rsplit(" ", 1)[0]: 0.0 for k in d["kernels"]}
        sk, mk = byName(s), byName(m)
        for k, v in s["kernels"].items():
            sk[k.rsplit(" ", 1)[0]] += v["attr"]
        for k, v in m["kernels"].items():
            mk[k.rsplit(" ", 1)[0]] += v["attr"]
        names = set(sk) | set(mk)
        growth = sorted(names, key=lambda k: -(mk.get(k, 0)-sk.get(k, 0)))
        extra = m["kernel_union_us"]-s["kernel_union_us"]
        wall = f"wall {s['unprofiled_us'][0]:.0f}->{m['unprofiled_us'][0]:.0f} us"
        cells = "; ".join(f"{k} {sk.get(k, 0):.1f}->{mk.get(k, 0):.1f} (+{mk.get(k, 0)-sk.get(k, 0):.1f})" for k in growth[:n])
        print(f"| {test} | {wall} | GPU busy {s['kernel_union_us']:.0f}->{m['kernel_union_us']:.0f} (+{extra:.0f}) | {cells} |")
